# CirCI on a Docker host: the app (ghcr.io/cir-ci/circi:<circi_version>), Postgres unless database
# is given, and Caddy when caddy is set. The same services as deploy/docker-compose.yml (+ the Caddy
# overlay), managed by Terraform. Changing circi_version pulls that image and replaces the container.

locals {
  # The settings' groups as the server gets them: every key, unset (null) unless the input sets it.
  # null leaves the setting out of the container's environment, so the server's default applies.
  smtp = merge({
    host   = null
    port   = null
    secure = null
    user   = null
    from   = null
  }, var.smtp)
  s3 = merge({
    bucket                  = null
    region                  = null
    endpoint                = null
    force_path_style        = null
    access_key_id           = null
    connect_timeout_seconds = null
    request_timeout_seconds = null
  }, var.s3)
  sign_in = merge({
    email    = null
    password = null
    sso      = null
  }, var.sign_in)
  sso = merge({
    github_client_id       = null
    google_client_id       = null
    gitlab_client_id       = null
    gitlab_url             = null
    oidc_issuer            = null
    oidc_client_id         = null
    oidc_name              = null
    oidc_trusted_for_email = null
  }, var.sso)
  github_app = merge({
    id                  = null
    api_url             = null
    api_timeout_seconds = null
  }, var.github_app)
  slack = merge({
    client_id = null
    api_url   = null
  }, var.slack)
  vapid = merge({
    public_key = null
    subject    = null
  }, var.vapid)
  sites = merge({
    host   = null
    max_mb = null
  }, var.sites)
  jobs = merge({
    upload_timeout_minutes = null
    gc_grace_hours         = null
    retention_days         = null
    retry_base_seconds     = null
    retry_max_seconds      = null
  }, var.jobs)
  webhooks = merge({
    timeout_seconds         = null
    allow_private_addresses = null
  }, var.webhooks)
  tuning = merge({
    database_pool_max = null
    diff_engine       = null
    diff_threads      = null
    live_max_streams  = null
  }, var.tuning)

  caddy = var.caddy == null ? null : merge({
    dashboard_host = null
    sites_host     = null
    aws_region     = "us-east-1"
  }, var.caddy)

  # Your own Postgres, or null for the bundled one.
  database = var.database == null ? null : merge({
    host           = null
    port           = 5432
    name           = "circi"
    user           = null
    tls            = true
    ca_certificate = null
  }, var.database)

  bundled_postgres = local.database == null
  caddy_address    = cidrhost(var.network_subnet, 10)
  secrets_dir      = "/run/circi/secrets"
  database_ca_path = "/run/circi/database-ca.pem"
  public_url       = local.caddy == null ? var.public_url : "https://${local.caddy.dashboard_host}"

  db = local.bundled_postgres ? {
    host     = "postgres"
    port     = 5432
    name     = "circi"
    user     = "circi"
    password = var.postgres_password
    query    = ""
    } : {
    host     = local.database.host
    port     = tonumber(local.database.port)
    name     = local.database.name
    user     = local.database.user
    password = var.database_password
    query = !local.database.tls ? "?sslmode=disable" : (
      "?sslmode=verify-full${local.database.ca_certificate == null ? "" : "&sslrootcert=${local.database_ca_path}"}"
    )
  }
  # URL-encoded: urlencode writes a space as +, which a URL's user part reads as a plus sign.
  encoded = { for name in ["user", "password", "name"] : name => replace(
    urlencode(local.db[name] == null ? "" : local.db[name]), "+", "%20",
  ) }
  database_url = format(
    "postgres://%s:%s@%s:%d/%s%s",
    local.encoded.user, local.encoded.password, local.db.host, local.db.port, local.encoded.name, local.db.query,
  )

  # Secrets go into the container as files, named by <NAME>_FILE, so its environment stays readable in
  # plan output. Which ones are set isn't secret, only their values.
  secrets = {
    BETTER_AUTH_SECRET        = var.better_auth_secret
    DATABASE_URL              = local.database_url
    S3_SECRET_ACCESS_KEY      = var.s3_secret_access_key
    SMTP_PASSWORD             = var.smtp_password
    AUTH_GITHUB_CLIENT_SECRET = var.auth_github_client_secret
    AUTH_GOOGLE_CLIENT_SECRET = var.auth_google_client_secret
    AUTH_GITLAB_CLIENT_SECRET = var.auth_gitlab_client_secret
    AUTH_OIDC_CLIENT_SECRET   = var.auth_oidc_client_secret
    GITHUB_APP_PRIVATE_KEY    = var.github_app_private_key
    GITHUB_APP_WEBHOOK_SECRET = var.github_app_webhook_secret
    SLACK_CLIENT_SECRET       = var.slack_client_secret
    VAPID_PRIVATE_KEY         = var.vapid_private_key
  }
  secret_names   = toset(nonsensitive([for name, value in local.secrets : name if value != null]))
  caddy_aws_keys = nonsensitive(var.caddy_aws_credentials != null)

  # Settings that go together: all set, or none (SETTING_GROUPS in packages/config/src/settings.ts;
  # the server checks them too, but only once the container starts).
  setting_groups = {
    "smtp.user / smtp_password"                                          = [local.smtp.user, var.smtp_password]
    "s3.access_key_id / s3_secret_access_key"                            = [local.s3.access_key_id, var.s3_secret_access_key]
    "github_app.id / github_app_private_key / github_app_webhook_secret" = [local.github_app.id, var.github_app_private_key, var.github_app_webhook_secret]
    "slack.client_id / slack_client_secret"                              = [local.slack.client_id, var.slack_client_secret]
    "vapid.public_key / vapid_private_key"                               = [local.vapid.public_key, var.vapid_private_key]
    "sso.github_client_id / auth_github_client_secret"                   = [local.sso.github_client_id, var.auth_github_client_secret]
    "sso.google_client_id / auth_google_client_secret"                   = [local.sso.google_client_id, var.auth_google_client_secret]
    "sso.gitlab_client_id / auth_gitlab_client_secret"                   = [local.sso.gitlab_client_id, var.auth_gitlab_client_secret]
    "sso.oidc_issuer / sso.oidc_client_id / auth_oidc_client_secret"     = [local.sso.oidc_issuer, local.sso.oidc_client_id, var.auth_oidc_client_secret]
  }
  half_set_groups = nonsensitive([
    for name, values in local.setting_groups : name if length(distinct([for v in values : v != null])) > 1
  ])
}

resource "docker_network" "circi" {
  name = var.name_prefix
  ipam_config {
    subnet = var.network_subnet
    # Docker picks this address itself; named here, or the provider reads it as a change and
    # replaces the network (and every container on it) on each apply.
    gateway = cidrhost(var.network_subnet, 1)
  }
}

resource "docker_volume" "files" {
  name = "${var.name_prefix}-files"
  lifecycle {
    prevent_destroy = true
  }
}

# --- Postgres -----------------------------------------------------------------------------------

resource "docker_volume" "pgdata" {
  count = local.bundled_postgres ? 1 : 0
  name  = "${var.name_prefix}-pgdata"
  lifecycle {
    prevent_destroy = true
  }
}

resource "docker_image" "postgres" {
  count        = local.bundled_postgres ? 1 : 0
  name         = var.postgres_image
  keep_locally = true
}

resource "docker_container" "postgres" {
  count   = local.bundled_postgres ? 1 : 0
  name    = "${var.name_prefix}-postgres"
  image   = docker_image.postgres[0].image_id
  restart = "unless-stopped"
  env = [
    "POSTGRES_USER=circi",
    "POSTGRES_PASSWORD=${var.postgres_password}",
    "POSTGRES_DB=circi",
  ]
  networks_advanced {
    name    = docker_network.circi.id
    aliases = ["postgres"]
  }
  # Postgres 18 images keep their data under /var/lib/postgresql/<major>/.
  volumes {
    volume_name    = docker_volume.pgdata[0].name
    container_path = "/var/lib/postgresql"
  }
  healthcheck {
    test     = ["CMD-SHELL", "pg_isready -U circi -d circi"]
    interval = "5s"
    timeout  = "3s"
    retries  = 20
  }
  wait = true

  lifecycle {
    # POSTGRES_PASSWORD only counts when the volume is first made: a new one is set with ALTER USER,
    # and replacing this container for it would change nothing but the downtime.
    ignore_changes = [env]
    precondition {
      condition     = var.postgres_password != null
      error_message = "Set postgres_password for the bundled Postgres, or database for your own."
    }
  }
}

# --- CirCI --------------------------------------------------------------------------------------

resource "docker_image" "circi" {
  name         = "${var.image_repository}:${var.circi_version}"
  keep_locally = true
}

resource "docker_container" "circi" {
  name    = var.name_prefix
  image   = docker_image.circi.image_id
  command = ["all"]
  restart = "unless-stopped"
  # Every setting the server reads (packages/config/src/schema.ts) that is set, then a <NAME>_FILE for
  # each secret. The image sets NODE_ENV, HOST, PORT, STORAGE_PATH, CIRCI_MIGRATIONS and CIRCI_WEB_DIST:
  # the port, the volume and the files here depend on them, so they are not inputs.
  env = concat([for name, value in {
    PUBLIC_URL                      = local.public_url
    PREVIOUS_PUBLIC_URLS            = length(var.previous_public_urls) == 0 ? null : join(",", var.previous_public_urls)
    TRUSTED_PROXIES                 = local.caddy != null ? local.caddy_address : length(var.trusted_proxies) == 0 ? null : join(",", var.trusted_proxies)
    LOG_LEVEL                       = var.log_level
    WORKSPACE_CREATION              = var.workspace_creation
    STORAGE_DRIVER                  = local.s3.bucket == null ? null : "s3"
    S3_BUCKET                       = local.s3.bucket
    S3_REGION                       = local.s3.region
    S3_ENDPOINT                     = local.s3.endpoint
    S3_FORCE_PATH_STYLE             = local.s3.force_path_style
    S3_ACCESS_KEY_ID                = local.s3.access_key_id
    S3_CONNECT_TIMEOUT_SECONDS      = local.s3.connect_timeout_seconds
    S3_REQUEST_TIMEOUT_SECONDS      = local.s3.request_timeout_seconds
    SMTP_HOST                       = local.smtp.host
    SMTP_PORT                       = local.smtp.port
    SMTP_SECURE                     = local.smtp.secure
    SMTP_USER                       = local.smtp.user
    SMTP_FROM                       = local.smtp.from
    AUTH_EMAIL_ENABLED              = local.sign_in.email
    AUTH_PASSWORD_ENABLED           = local.sign_in.password
    AUTH_SSO_ENABLED                = local.sign_in.sso
    AUTH_GITHUB_CLIENT_ID           = local.sso.github_client_id
    AUTH_GOOGLE_CLIENT_ID           = local.sso.google_client_id
    AUTH_GITLAB_CLIENT_ID           = local.sso.gitlab_client_id
    AUTH_GITLAB_URL                 = local.sso.gitlab_url
    AUTH_OIDC_ISSUER                = local.sso.oidc_issuer
    AUTH_OIDC_CLIENT_ID             = local.sso.oidc_client_id
    AUTH_OIDC_NAME                  = local.sso.oidc_name
    AUTH_OIDC_TRUSTED_FOR_EMAIL     = local.sso.oidc_trusted_for_email
    GITHUB_APP_ID                   = local.github_app.id
    GITHUB_API_URL                  = local.github_app.api_url
    GITHUB_API_TIMEOUT_SECONDS      = local.github_app.api_timeout_seconds
    SLACK_CLIENT_ID                 = local.slack.client_id
    SLACK_API_URL                   = local.slack.api_url
    VAPID_PUBLIC_KEY                = local.vapid.public_key
    VAPID_SUBJECT                   = local.vapid.subject
    STATIC_SITES_HOST               = local.caddy != null ? local.caddy.sites_host : local.sites.host
    STATIC_SITES_MAX_MB             = local.sites.max_mb
    UPLOAD_TIMEOUT_MINUTES          = local.jobs.upload_timeout_minutes
    GC_GRACE_HOURS                  = local.jobs.gc_grace_hours
    JOB_RETENTION_DAYS              = local.jobs.retention_days
    JOB_RETRY_BASE_SECONDS          = local.jobs.retry_base_seconds
    JOB_RETRY_MAX_SECONDS           = local.jobs.retry_max_seconds
    WEBHOOK_TIMEOUT_SECONDS         = local.webhooks.timeout_seconds
    WEBHOOK_ALLOW_PRIVATE_ADDRESSES = local.webhooks.allow_private_addresses
    DATABASE_POOL_MAX               = local.tuning.database_pool_max
    CIRCI_DIFF_ENGINE               = local.tuning.diff_engine
    CIRCI_DIFF_THREADS              = local.tuning.diff_threads
    LIVE_MAX_STREAMS                = local.tuning.live_max_streams
    } : "${name}=${tostring(value)}" if value != null],
    [for name in local.secret_names : "${name}_FILE=${local.secrets_dir}/${name}"],
  )

  dynamic "upload" {
    for_each = local.secret_names
    content {
      file    = "${local.secrets_dir}/${upload.value}"
      content = local.secrets[upload.value]
    }
  }
  dynamic "upload" {
    for_each = local.bundled_postgres ? [] : compact([local.database.ca_certificate])
    content {
      file    = local.database_ca_path
      content = upload.value
    }
  }

  networks_advanced {
    name    = docker_network.circi.id
    aliases = ["circi"] # the Caddyfile proxies to circi:3000
  }
  volumes {
    volume_name    = docker_volume.files.name
    container_path = "/var/lib/circi/files"
  }
  dynamic "ports" {
    for_each = local.caddy == null ? [var.port] : []
    content {
      internal = 3000
      external = ports.value
    }
  }

  # Apply waits for the image's own health check (/healthz), so a version that doesn't start fails
  # the apply instead of leaving a restarting container.
  wait         = true
  wait_timeout = 180

  depends_on = [docker_container.postgres]

  lifecycle {
    # The server checks these too, but only once the container starts: here they fail the plan.
    precondition {
      condition     = local.bundled_postgres || var.database_password != null
      error_message = "Set database_password with database."
    }
    precondition {
      condition     = length(local.half_set_groups) == 0
      error_message = "These settings go together, set all of each or none: ${join("; ", local.half_set_groups)}."
    }
    precondition {
      condition     = local.smtp.host == null || local.smtp.from != null
      error_message = "smtp.from is required with smtp.host."
    }
    precondition {
      condition     = local.s3.bucket != null || alltrue([for v in values(local.s3) : v == null])
      error_message = "s3 needs a bucket."
    }
    precondition {
      condition     = local.caddy == null || (local.sites.host == null && length(var.trusted_proxies) == 0)
      error_message = "With caddy, sites.host is caddy.sites_host and trusted_proxies is Caddy's address: leave both unset."
    }
  }
}

# --- Caddy --------------------------------------------------------------------------------------

resource "docker_volume" "caddy_data" {
  count = local.caddy == null ? 0 : 1
  name  = "${var.name_prefix}-caddy-data"
}

resource "docker_volume" "caddy_config" {
  count = local.caddy == null ? 0 : 1
  name  = "${var.name_prefix}-caddy-config"
}

resource "docker_image" "caddy" {
  count        = local.caddy == null ? 0 : 1
  name         = "${var.image_repository}-caddy:${var.circi_version}"
  keep_locally = true
}

resource "docker_container" "caddy" {
  count   = local.caddy == null ? 0 : 1
  name    = "${var.name_prefix}-caddy"
  image   = docker_image.caddy[0].image_id
  restart = "unless-stopped"
  env = concat(
    [
      "DASHBOARD_HOST=${local.caddy.dashboard_host}",
      "SITES_HOST=${local.caddy.sites_host}",
      "AWS_REGION=${local.caddy.aws_region}",
    ],
    local.caddy_aws_keys ? ["AWS_SHARED_CREDENTIALS_FILE=/run/caddy/aws-credentials"] : [],
  )
  # Route53 keys as a file too (the AWS SDK in Caddy reads a shared credentials file), so they stay
  # out of the container's environment and the plan.
  dynamic "upload" {
    for_each = local.caddy_aws_keys ? ["credentials"] : []
    content {
      file    = "/run/caddy/aws-credentials"
      content = <<-EOT
        [default]
        aws_access_key_id = ${var.caddy_aws_credentials.access_key_id}
        aws_secret_access_key = ${var.caddy_aws_credentials.secret_access_key}
      EOT
    }
  }
  networks_advanced {
    name         = docker_network.circi.id
    ipv4_address = local.caddy_address # the one proxy the app trusts (TRUSTED_PROXIES)
  }
  upload {
    file    = "/etc/caddy/Caddyfile"
    content = file("${path.module}/Caddyfile")
  }
  volumes {
    volume_name    = docker_volume.caddy_data[0].name
    container_path = "/data"
  }
  volumes {
    volume_name    = docker_volume.caddy_config[0].name
    container_path = "/config"
  }
  ports {
    internal = 80
    external = 80
  }
  ports {
    internal = 443
    external = 443
  }
  ports {
    internal = 443
    external = 443
    protocol = "udp"
  }

  depends_on = [docker_container.circi]
}
