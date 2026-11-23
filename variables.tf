# The server's settings in groups (smtp, s3, sso, ...), each key named after its setting: smtp.host is
# SMTP_HOST. The groups are typed `any` and checked here, key by key, because an object type would
# silently drop a misspelled key; a key that isn't the group's fails the plan. A key left out, or null,
# leaves the setting unset: the server's default applies, and settings the dashboard can change
# (Instance > Settings) stay changeable there. A setting that is set is locked in the dashboard.
#
# Secrets are variables of their own, named after the setting in lower case (smtp_password is
# SMTP_PASSWORD) and marked sensitive: they reach the container as files (`<NAME>_FILE`, read by the
# server), so the rest stays readable in plan output. The server's settings and which are secret are
# listed in packages/config/src/settings.ts; packages/config/test/deploy-settings.test.ts holds this
# module to them.

# --- The release --------------------------------------------------------------------------------

variable "circi_version" {
  description = "The CirCI release to run, e.g. \"0.1.0\": the tag of ghcr.io/cir-ci/circi (and of the Caddy image). Change it and apply to update; the server applies database migrations when it starts."
  type        = string
  validation {
    condition     = can(regex("^\\d+\\.\\d+\\.\\d+(-[0-9A-Za-z.-]+)?$", var.circi_version))
    error_message = "circi_version is a release version such as 0.1.0 (see the GitHub releases named @circi/server@<version>)."
  }
}

variable "image_repository" {
  description = "Where the CirCI image comes from. The Caddy image is the same name with -caddy."
  type        = string
  default     = "ghcr.io/cir-ci/circi"
}

variable "name_prefix" {
  description = "Prefix for the containers, volumes and network, so two installs can share a host."
  type        = string
  default     = "circi"
}

variable "log_level" {
  description = "LOG_LEVEL: fatal, error, warn, info (default), debug or trace."
  type        = string
  default     = null
  validation {
    condition     = contains(["fatal", "error", "warn", "info", "debug", "trace"], coalesce(var.log_level, "info"))
    error_message = "log_level is one of fatal, error, warn, info, debug, trace."
  }
}

# --- Address and network ------------------------------------------------------------------------

variable "public_url" {
  description = "The dashboard's address (PUBLIC_URL), e.g. https://ci.acme.io. Ignored when caddy is set: it becomes https://<caddy.dashboard_host>."
  type        = string
  default     = "http://localhost:3000"
}

variable "previous_public_urls" {
  description = "Old dashboard addresses (PREVIOUS_PUBLIC_URLS), redirected to public_url so links in old PR comments and emails keep working."
  type        = list(string)
  default     = []
}

variable "port" {
  description = "Host port the app is published on when caddy is null (with Caddy, only 80 and 443 are published)."
  type        = number
  default     = 3000
}

variable "trusted_proxies" {
  description = "Without caddy: your proxy's addresses or CIDR ranges (TRUSTED_PROXIES), believed when they say who the client is. With caddy the module sets it to Caddy's address."
  type        = list(string)
  default     = []
}

variable "network_subnet" {
  description = "The Docker network's subnet. Caddy gets its 10th address, the only proxy the app trusts. It must not overlap a network the host reaches (an AWS default VPC is 172.31.0.0/16), or traffic to it (e.g. RDS) is routed into Docker."
  type        = string
  default     = "192.168.250.0/24"
  validation {
    condition     = can(cidrhost(var.network_subnet, 10))
    error_message = "network_subnet is an IPv4 CIDR range with at least 16 addresses, e.g. 192.168.250.0/24."
  }
}

variable "caddy" {
  description = <<-EOT
    TLS for the dashboard and hosted sites with Caddy, configured by the module's Caddyfile (read https://circi.dev/self-hosting/site-domains/ first). Route53 credentials come from the host's instance role, or caddy_aws_credentials.
      dashboard_host  string  required, e.g. ci.acme.io
      sites_host      string  required, a domain used for nothing else
      aws_region      string  Route53's region (default us-east-1)
  EOT
  type        = any
  default     = null
  validation {
    condition     = var.caddy == null || try(length(setsubtract(keys(var.caddy), ["dashboard_host", "sites_host", "aws_region"])) == 0, false)
    error_message = "caddy takes dashboard_host, sites_host, aws_region: ${join(", ", try(setsubtract(keys(var.caddy), ["dashboard_host", "sites_host", "aws_region"]), ["it must be an object"]))} isn't one."
  }
  validation {
    condition     = var.caddy == null || try(var.caddy.dashboard_host != "" && var.caddy.sites_host != "", false)
    error_message = "caddy needs dashboard_host and sites_host."
  }
}

variable "caddy_aws_credentials" {
  description = "Route53 credentials for Caddy's wildcard certificate, when the host has no instance role."
  type = object({
    access_key_id     = string
    secret_access_key = string
  })
  default   = null
  sensitive = true
}

# --- The database -------------------------------------------------------------------------------

variable "postgres_password" {
  description = "Password of the bundled Postgres; needed when database is null. Postgres takes it only when its volume is first made: to change it later, run ALTER USER circi PASSWORD '...' in the database first, then apply."
  type        = string
  default     = null
  sensitive   = true
}

variable "postgres_image" {
  description = "The bundled Postgres's image. Keep the major version: a new major needs a dump and restore."
  type        = string
  default     = "postgres:18-alpine"
}

variable "database" {
  description = <<-EOT
    Your own Postgres 13+ (Amazon RDS, Cloud SQL, ...) instead of the bundled one, with its password in database_password. Connect directly, not through RDS Proxy or PgBouncer in transaction mode: the server LISTENs and holds session locks.
      host            string  required
      port            number  default 5432
      name            string  default circi
      user            string  required
      tls             bool    verify the server's certificate, sslmode=verify-full (default true)
      ca_certificate  string  the PEM it chains to when that isn't a public CA (RDS: https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem)
  EOT
  type        = any
  default     = null
  validation {
    condition     = var.database == null || try(length(setsubtract(keys(var.database), ["host", "port", "name", "user", "tls", "ca_certificate"])) == 0, false)
    error_message = "database takes host, port, name, user, tls, ca_certificate: ${join(", ", try(setsubtract(keys(var.database), ["host", "port", "name", "user", "tls", "ca_certificate"]), ["it must be an object"]))} isn't one."
  }
  validation {
    condition     = var.database == null || try(var.database.host != "" && var.database.user != "", false)
    error_message = "database needs host and user."
  }
  validation {
    condition     = can(tonumber(try(var.database.port, null))) && can(tobool(try(var.database.tls, null)))
    error_message = "In database, port is a number and tls is true or false."
  }
  validation {
    condition     = try(var.database.tls, true) || try(var.database.ca_certificate, null) == null
    error_message = "database.ca_certificate is only used with tls = true."
  }
}

# --- Secrets ------------------------------------------------------------------------------------

variable "better_auth_secret" {
  description = "Signs sessions and cookies (BETTER_AUTH_SECRET, 32+ characters; openssl rand -base64 32). Keep it stable: changing it signs everyone out."
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.better_auth_secret) >= 32
    error_message = "better_auth_secret must be at least 32 characters (openssl rand -base64 32)."
  }
}

variable "database_password" {
  description = "The password of database.user (any characters: the module encodes it). IAM database authentication isn't supported."
  type        = string
  default     = null
  sensitive   = true
}

variable "smtp_password" {
  description = "SMTP_PASSWORD, with smtp.user."
  type        = string
  default     = null
  sensitive   = true
}

variable "s3_secret_access_key" {
  description = "S3_SECRET_ACCESS_KEY, with s3.access_key_id."
  type        = string
  default     = null
  sensitive   = true
}

variable "github_app_private_key" {
  description = "GITHUB_APP_PRIVATE_KEY: the App's PEM key, e.g. file(\"circi.private-key.pem\")."
  type        = string
  default     = null
  sensitive   = true
}

variable "github_app_webhook_secret" {
  description = "GITHUB_APP_WEBHOOK_SECRET."
  type        = string
  default     = null
  sensitive   = true
}

variable "slack_client_secret" {
  description = "SLACK_CLIENT_SECRET, with slack.client_id."
  type        = string
  default     = null
  sensitive   = true
}

variable "vapid_private_key" {
  description = "VAPID_PRIVATE_KEY, with vapid.public_key."
  type        = string
  default     = null
  sensitive   = true
}

variable "auth_github_client_secret" {
  description = "AUTH_GITHUB_CLIENT_SECRET, with sso.github_client_id."
  type        = string
  default     = null
  sensitive   = true
}

variable "auth_google_client_secret" {
  description = "AUTH_GOOGLE_CLIENT_SECRET, with sso.google_client_id."
  type        = string
  default     = null
  sensitive   = true
}

variable "auth_gitlab_client_secret" {
  description = "AUTH_GITLAB_CLIENT_SECRET, with sso.gitlab_client_id."
  type        = string
  default     = null
  sensitive   = true
}

variable "auth_oidc_client_secret" {
  description = "AUTH_OIDC_CLIENT_SECRET, with sso.oidc_issuer and sso.oidc_client_id."
  type        = string
  default     = null
  sensitive   = true
}

# --- Settings, by area -----------------------------------------------------------------------------

variable "smtp" {
  description = <<-EOT
    Outgoing mail, for email sign-in codes and invitations. Set, it locks the mail settings in the dashboard. The password is smtp_password.
      host    string  SMTP_HOST
      port    number  SMTP_PORT (default 465 with secure, else 587)
      secure  bool    SMTP_SECURE: implicit TLS (default: true on port 465)
      user    string  SMTP_USER, set with smtp_password
      from    string  SMTP_FROM, e.g. "CirCI <ci@acme.io>"; required with host
  EOT
  type        = any
  default     = {}
  validation {
    condition     = var.smtp == null || try(length(setsubtract(keys(var.smtp), ["host", "port", "secure", "user", "from"])) == 0, false)
    error_message = "smtp takes host, port, secure, user, from: ${join(", ", try(setsubtract(keys(var.smtp), ["host", "port", "secure", "user", "from"]), ["it must be an object"]))} isn't one."
  }
  validation {
    condition     = alltrue([for k in ["port"] : can(tonumber(try(var.smtp[k], null)))])
    error_message = "In smtp, port is a number."
  }
  validation {
    condition     = alltrue([for k in ["secure"] : can(tobool(try(var.smtp[k], null)))])
    error_message = "In smtp, secure is true or false."
  }
  validation {
    condition     = alltrue([for k in ["host", "user", "from"] : can(tostring(try(var.smtp[k], null)))])
    error_message = "In smtp, host, user, from are each a string."
  }
}

variable "s3" {
  description = <<-EOT
    Keep screenshots in S3 (STORAGE_DRIVER=s3) instead of the host's volume. Without access_key_id and s3_secret_access_key the server uses the host's instance role (an EC2 instance needs its metadata hop limit at 2 for a container to reach it).
      bucket                   string  S3_BUCKET; required
      region                   string  S3_REGION (default us-east-1)
      endpoint                 string  S3_ENDPOINT: an S3-compatible store (MinIO, R2, ...)
      force_path_style         bool    S3_FORCE_PATH_STYLE (default: true with endpoint)
      access_key_id            string  S3_ACCESS_KEY_ID, set with s3_secret_access_key
      connect_timeout_seconds  number  S3_CONNECT_TIMEOUT_SECONDS (default 10)
      request_timeout_seconds  number  S3_REQUEST_TIMEOUT_SECONDS: silence allowed on an open request (default 60)
  EOT
  type        = any
  default     = {}
  validation {
    condition     = var.s3 == null || try(length(setsubtract(keys(var.s3), ["bucket", "region", "endpoint", "force_path_style", "access_key_id", "connect_timeout_seconds", "request_timeout_seconds"])) == 0, false)
    error_message = "s3 takes bucket, region, endpoint, force_path_style, access_key_id, connect_timeout_seconds, request_timeout_seconds: ${join(", ", try(setsubtract(keys(var.s3), ["bucket", "region", "endpoint", "force_path_style", "access_key_id", "connect_timeout_seconds", "request_timeout_seconds"]), ["it must be an object"]))} isn't one."
  }
  validation {
    condition     = alltrue([for k in ["connect_timeout_seconds", "request_timeout_seconds"] : can(tonumber(try(var.s3[k], null)))])
    error_message = "In s3, connect_timeout_seconds, request_timeout_seconds are each a number."
  }
  validation {
    condition     = alltrue([for k in ["force_path_style"] : can(tobool(try(var.s3[k], null)))])
    error_message = "In s3, force_path_style is true or false."
  }
  validation {
    condition     = alltrue([for k in ["bucket", "region", "endpoint", "access_key_id"] : can(tostring(try(var.s3[k], null)))])
    error_message = "In s3, bucket, region, endpoint, access_key_id are each a string."
  }
}

variable "sign_in" {
  description = <<-EOT
    Sign-in methods. Each one set locks it in the dashboard.
      email     bool    AUTH_EMAIL_ENABLED: email codes (default on when SMTP is set)
      password  bool    AUTH_PASSWORD_ENABLED (default on)
      sso       bool    AUTH_SSO_ENABLED: the providers in sso (default on)
  EOT
  type        = any
  default     = {}
  validation {
    condition     = var.sign_in == null || try(length(setsubtract(keys(var.sign_in), ["email", "password", "sso"])) == 0, false)
    error_message = "sign_in takes email, password, sso: ${join(", ", try(setsubtract(keys(var.sign_in), ["email", "password", "sso"]), ["it must be an object"]))} isn't one."
  }
  validation {
    condition     = alltrue([for k in ["email", "password", "sso"] : can(tobool(try(var.sign_in[k], null)))])
    error_message = "In sign_in, email, password, sso are each true or false."
  }
}

variable "sso" {
  description = <<-EOT
    Single sign-on providers; each client ID goes with its secret variable (auth_github_client_secret, ...). Callbacks: <public_url>/api/auth/callback/<github|google|gitlab|oidc>.
      github_client_id        string  AUTH_GITHUB_CLIENT_ID
      google_client_id        string  AUTH_GOOGLE_CLIENT_ID
      gitlab_client_id        string  AUTH_GITLAB_CLIENT_ID
      gitlab_url              string  AUTH_GITLAB_URL: a self-managed GitLab (default gitlab.com)
      oidc_issuer             string  AUTH_OIDC_ISSUER: any OpenID Connect provider
      oidc_client_id          string  AUTH_OIDC_CLIENT_ID
      oidc_name               string  AUTH_OIDC_NAME: the button's label (default "Single sign-on")
      oidc_trusted_for_email  bool    AUTH_OIDC_TRUSTED_FOR_EMAIL: true only if the provider verifies every address (default false)
  EOT
  type        = any
  default     = {}
  validation {
    condition     = var.sso == null || try(length(setsubtract(keys(var.sso), ["github_client_id", "google_client_id", "gitlab_client_id", "gitlab_url", "oidc_issuer", "oidc_client_id", "oidc_name", "oidc_trusted_for_email"])) == 0, false)
    error_message = "sso takes github_client_id, google_client_id, gitlab_client_id, gitlab_url, oidc_issuer, oidc_client_id, oidc_name, oidc_trusted_for_email: ${join(", ", try(setsubtract(keys(var.sso), ["github_client_id", "google_client_id", "gitlab_client_id", "gitlab_url", "oidc_issuer", "oidc_client_id", "oidc_name", "oidc_trusted_for_email"]), ["it must be an object"]))} isn't one."
  }
  validation {
    condition     = alltrue([for k in ["oidc_trusted_for_email"] : can(tobool(try(var.sso[k], null)))])
    error_message = "In sso, oidc_trusted_for_email is true or false."
  }
  validation {
    condition     = alltrue([for k in ["github_client_id", "google_client_id", "gitlab_client_id", "gitlab_url", "oidc_issuer", "oidc_client_id", "oidc_name"] : can(tostring(try(var.sso[k], null)))])
    error_message = "In sso, github_client_id, google_client_id, gitlab_client_id, gitlab_url, oidc_issuer, oidc_client_id, oidc_name are each a string."
  }
}

variable "github_app" {
  description = <<-EOT
    The GitHub App, for checks and pull request comments; its key and webhook secret are github_app_private_key and github_app_webhook_secret.
      id                   string  GITHUB_APP_ID
      api_url              string  GITHUB_API_URL: GitHub Enterprise Server's API
      api_timeout_seconds  number  GITHUB_API_TIMEOUT_SECONDS (default 15)
  EOT
  type        = any
  default     = {}
  validation {
    condition     = var.github_app == null || try(length(setsubtract(keys(var.github_app), ["id", "api_url", "api_timeout_seconds"])) == 0, false)
    error_message = "github_app takes id, api_url, api_timeout_seconds: ${join(", ", try(setsubtract(keys(var.github_app), ["id", "api_url", "api_timeout_seconds"]), ["it must be an object"]))} isn't one."
  }
  validation {
    condition     = alltrue([for k in ["api_timeout_seconds"] : can(tonumber(try(var.github_app[k], null)))])
    error_message = "In github_app, api_timeout_seconds is a number."
  }
  validation {
    condition     = alltrue([for k in ["id", "api_url"] : can(tostring(try(var.github_app[k], null)))])
    error_message = "In github_app, id, api_url are each a string."
  }
}

variable "slack" {
  description = <<-EOT
    The Slack app; its secret is slack_client_secret. Set, it locks the Slack settings in the dashboard.
      client_id  string  SLACK_CLIENT_ID
      api_url    string  SLACK_API_URL (default https://slack.com/api)
  EOT
  type        = any
  default     = {}
  validation {
    condition     = var.slack == null || try(length(setsubtract(keys(var.slack), ["client_id", "api_url"])) == 0, false)
    error_message = "slack takes client_id, api_url: ${join(", ", try(setsubtract(keys(var.slack), ["client_id", "api_url"]), ["it must be an object"]))} isn't one."
  }
  validation {
    condition     = alltrue([for k in ["client_id", "api_url"] : can(tostring(try(var.slack[k], null)))])
    error_message = "In slack, client_id, api_url are each a string."
  }
}

variable "vapid" {
  description = <<-EOT
    Pinned web push keys (the private one is vapid_private_key). Unset, the server makes its own and keeps them in the database.
      public_key  string  VAPID_PUBLIC_KEY
      subject     string  VAPID_SUBJECT: mailto: or https: contact (default public_url)
  EOT
  type        = any
  default     = {}
  validation {
    condition     = var.vapid == null || try(length(setsubtract(keys(var.vapid), ["public_key", "subject"])) == 0, false)
    error_message = "vapid takes public_key, subject: ${join(", ", try(setsubtract(keys(var.vapid), ["public_key", "subject"]), ["it must be an object"]))} isn't one."
  }
  validation {
    condition     = alltrue([for k in ["public_key", "subject"] : can(tostring(try(var.vapid[k], null)))])
    error_message = "In vapid, public_key, subject are each a string."
  }
}

variable "sites" {
  description = <<-EOT
    Hosted sites.
      host    string  STATIC_SITES_HOST, without caddy (with caddy it is caddy.sites_host): a domain used for nothing else
      max_mb  number  STATIC_SITES_MAX_MB: the largest upload (default 200; locks the dashboard setting)
  EOT
  type        = any
  default     = {}
  validation {
    condition     = var.sites == null || try(length(setsubtract(keys(var.sites), ["host", "max_mb"])) == 0, false)
    error_message = "sites takes host, max_mb: ${join(", ", try(setsubtract(keys(var.sites), ["host", "max_mb"]), ["it must be an object"]))} isn't one."
  }
  validation {
    condition     = alltrue([for k in ["max_mb"] : can(tonumber(try(var.sites[k], null)))])
    error_message = "In sites, max_mb is a number."
  }
  validation {
    condition     = alltrue([for k in ["host"] : can(tostring(try(var.sites[k], null)))])
    error_message = "In sites, host is a string."
  }
}

variable "jobs" {
  description = <<-EOT
    Builds, background jobs and retention. Each one set except the retries locks it in the dashboard.
      upload_timeout_minutes  number  UPLOAD_TIMEOUT_MINUTES: builds still uploading after this long fail (default 60, 0 = never)
      gc_grace_hours          number  GC_GRACE_HOURS: unused files are kept this long (default 24)
      retention_days          number  JOB_RETENTION_DAYS: finished jobs are kept this long (default 14)
      retry_base_seconds      number  JOB_RETRY_BASE_SECONDS: first wait before a retry, doubling after (default 2)
      retry_max_seconds       number  JOB_RETRY_MAX_SECONDS: the longest wait between attempts (default 300)
  EOT
  type        = any
  default     = {}
  validation {
    condition     = var.jobs == null || try(length(setsubtract(keys(var.jobs), ["upload_timeout_minutes", "gc_grace_hours", "retention_days", "retry_base_seconds", "retry_max_seconds"])) == 0, false)
    error_message = "jobs takes upload_timeout_minutes, gc_grace_hours, retention_days, retry_base_seconds, retry_max_seconds: ${join(", ", try(setsubtract(keys(var.jobs), ["upload_timeout_minutes", "gc_grace_hours", "retention_days", "retry_base_seconds", "retry_max_seconds"]), ["it must be an object"]))} isn't one."
  }
  validation {
    condition     = alltrue([for k in ["upload_timeout_minutes", "gc_grace_hours", "retention_days", "retry_base_seconds", "retry_max_seconds"] : can(tonumber(try(var.jobs[k], null)))])
    error_message = "In jobs, upload_timeout_minutes, gc_grace_hours, retention_days, retry_base_seconds, retry_max_seconds are each a number."
  }
}

variable "webhooks" {
  description = <<-EOT
    Outgoing webhooks.
      timeout_seconds          number  WEBHOOK_TIMEOUT_SECONDS: how long a receiver may take (default 10; locks the dashboard setting)
      allow_private_addresses  bool    WEBHOOK_ALLOW_PRIVATE_ADDRESSES: only if your receivers live on your own network (default false)
  EOT
  type        = any
  default     = {}
  validation {
    condition     = var.webhooks == null || try(length(setsubtract(keys(var.webhooks), ["timeout_seconds", "allow_private_addresses"])) == 0, false)
    error_message = "webhooks takes timeout_seconds, allow_private_addresses: ${join(", ", try(setsubtract(keys(var.webhooks), ["timeout_seconds", "allow_private_addresses"]), ["it must be an object"]))} isn't one."
  }
  validation {
    condition     = alltrue([for k in ["timeout_seconds"] : can(tonumber(try(var.webhooks[k], null)))])
    error_message = "In webhooks, timeout_seconds is a number."
  }
  validation {
    condition     = alltrue([for k in ["allow_private_addresses"] : can(tobool(try(var.webhooks[k], null)))])
    error_message = "In webhooks, allow_private_addresses is true or false."
  }
}

variable "tuning" {
  description = <<-EOT
    Performance settings.
      database_pool_max  number  DATABASE_POOL_MAX: the server pool's connections (default 10; it opens a few more of its own)
      diff_engine        string  CIRCI_DIFF_ENGINE: native (default), js-workers or js
      diff_threads       number  CIRCI_DIFF_THREADS: threads of js-workers (default: cores - 1)
      live_max_streams   number  LIVE_MAX_STREAMS: live dashboard streams one server keeps open (default 2000)
  EOT
  type        = any
  default     = {}
  validation {
    condition     = var.tuning == null || try(length(setsubtract(keys(var.tuning), ["database_pool_max", "diff_engine", "diff_threads", "live_max_streams"])) == 0, false)
    error_message = "tuning takes database_pool_max, diff_engine, diff_threads, live_max_streams: ${join(", ", try(setsubtract(keys(var.tuning), ["database_pool_max", "diff_engine", "diff_threads", "live_max_streams"]), ["it must be an object"]))} isn't one."
  }
  validation {
    condition     = alltrue([for k in ["database_pool_max", "diff_threads", "live_max_streams"] : can(tonumber(try(var.tuning[k], null)))])
    error_message = "In tuning, database_pool_max, diff_threads, live_max_streams are each a number."
  }
  validation {
    condition     = alltrue([for k in ["diff_engine"] : can(tostring(try(var.tuning[k], null)))])
    error_message = "In tuning, diff_engine is a string."
  }
  validation {
    condition     = try(var.tuning.diff_engine, null) == null || contains(["native", "js-workers", "js"], try(var.tuning.diff_engine, ""))
    error_message = "tuning.diff_engine is native, js-workers or js."
  }
}


variable "workspace_creation" {
  description = "WORKSPACE_CREATION: who may create workspaces, \"admin\" (default) or \"anyone\". Locks the dashboard setting."
  type        = string
  default     = null
  validation {
    condition     = contains(["admin", "anyone"], coalesce(var.workspace_creation, "admin"))
    error_message = "workspace_creation is \"admin\" or \"anyone\"."
  }
}
