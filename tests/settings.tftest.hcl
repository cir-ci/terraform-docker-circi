# terraform test (no Docker needed: the provider is mocked). Checks what reaches the containers.

mock_provider "docker" {}

variables {
  circi_version      = "1.2.3"
  better_auth_secret = "a-secret-that-is-at-least-32-characters-long"
  postgres_password  = "ab/Cd+e= f"
}

run "bundled_postgres_encodes_the_password" {
  command = plan

  assert {
    condition     = nonsensitive(local.database_url) == "postgres://circi:ab%2FCd%2Be%3D%20f@postgres:5432/circi"
    error_message = "The bundled Postgres's URL must encode the password: ${nonsensitive(local.database_url)}"
  }
  assert {
    condition     = contains(docker_container.circi.env, "DATABASE_URL_FILE=/run/circi/secrets/DATABASE_URL")
    error_message = "DATABASE_URL reaches the server as a file."
  }
  assert {
    condition     = length([for e in docker_container.circi.env : e if startswith(e, "BETTER_AUTH_SECRET=") || startswith(e, "DATABASE_URL=")]) == 0
    error_message = "No secret may sit in the environment."
  }
  assert {
    condition     = !issensitive(docker_container.circi.env)
    error_message = "The environment stays readable in plan output."
  }
  assert {
    condition     = length(docker_container.postgres) == 1
    error_message = "Without database, Postgres runs in a container."
  }
}

run "unset_settings_stay_unset" {
  command = plan

  assert {
    condition     = toset([for e in docker_container.circi.env : split("=", e)[0]]) == toset(["PUBLIC_URL", "BETTER_AUTH_SECRET_FILE", "DATABASE_URL_FILE"])
    error_message = "Only PUBLIC_URL and the two required secrets are set by default: ${join(", ", docker_container.circi.env)}"
  }
}

run "rds_with_its_certificate_bundle" {
  command = plan

  variables {
    postgres_password = null
    database = {
      host           = "circi.abc123.eu-west-1.rds.amazonaws.com"
      user           = "circi_app"
      ca_certificate = "-----BEGIN CERTIFICATE-----\nRDS\n-----END CERTIFICATE-----\n"
    }
    database_password = "p@ss:w/rd"
    tuning            = { database_pool_max = 20 }
  }

  assert {
    condition     = nonsensitive(local.database_url) == "postgres://circi_app:p%40ss%3Aw%2Frd@circi.abc123.eu-west-1.rds.amazonaws.com:5432/circi?sslmode=verify-full&sslrootcert=/run/circi/database-ca.pem"
    error_message = "RDS: verify-full against the uploaded bundle: ${nonsensitive(local.database_url)}"
  }
  assert {
    condition     = length(docker_container.postgres) == 0 && length(docker_volume.pgdata) == 0
    error_message = "With database, no Postgres container or volume."
  }
  assert {
    condition     = contains(docker_container.circi.env, "DATABASE_POOL_MAX=20")
    error_message = "tuning.database_pool_max reaches the server."
  }
}

run "database_without_tls" {
  command = plan

  variables {
    postgres_password = null
    database          = { host = "10.0.0.5", port = 6543, name = "ci", user = "ci", tls = false }
    database_password = "x"
  }

  assert {
    condition     = nonsensitive(local.database_url) == "postgres://ci:x@10.0.0.5:6543/ci?sslmode=disable"
    error_message = "tls = false: ${nonsensitive(local.database_url)}"
  }
}

run "database_needs_its_password" {
  command = plan

  variables {
    postgres_password = null
    database          = { host = "db", user = "ci" }
  }

  expect_failures = [docker_container.circi]
}

run "typed_settings_and_secrets" {
  command = plan

  variables {
    log_level = "debug"
    smtp = {
      host = "email-smtp.eu-west-1.amazonaws.com"
      from = "CirCI <ci@acme.io>"
      user = "AKIA"
    }
    smtp_password        = "smtp-secret"
    s3                   = { bucket = "acme-circi", region = "eu-west-1" }
    previous_public_urls = ["https://old.acme.io", "https://older.acme.io"]
    trusted_proxies      = ["10.0.0.0/8"]
    sign_in              = { sso = false }
  }

  assert {
    condition = alltrue([for e in [
      "LOG_LEVEL=debug",
      "SMTP_HOST=email-smtp.eu-west-1.amazonaws.com",
      "SMTP_USER=AKIA",
      "SMTP_PASSWORD_FILE=/run/circi/secrets/SMTP_PASSWORD",
      "STORAGE_DRIVER=s3",
      "S3_BUCKET=acme-circi",
      "S3_REGION=eu-west-1",
      "PREVIOUS_PUBLIC_URLS=https://old.acme.io,https://older.acme.io",
      "TRUSTED_PROXIES=10.0.0.0/8",
      "AUTH_SSO_ENABLED=false",
    ] : contains(docker_container.circi.env, e)])
    error_message = "Settings reach the server: ${join(", ", docker_container.circi.env)}"
  }
  assert {
    condition     = !issensitive(docker_container.circi.env)
    error_message = "The environment stays readable with secrets set."
  }
}

run "half_a_pair_fails_the_plan" {
  command = plan

  variables {
    smtp = { host = "smtp.acme.io", from = "ci@acme.io", user = "ci" }
  }

  expect_failures = [docker_container.circi]
}

run "bad_values_fail_validation" {
  command = plan

  variables {
    log_level          = "verbose"
    better_auth_secret = "short"
  }

  expect_failures = [var.log_level, var.better_auth_secret]
}

run "caddy_is_the_one_trusted_proxy" {
  command = plan

  variables {
    caddy = { dashboard_host = "ci.acme.io", sites_host = "acme-sites.com" }
    caddy_aws_credentials = {
      access_key_id     = "AKIAEXAMPLE"
      secret_access_key = "route53-secret"
    }
  }

  assert {
    condition = alltrue([for e in [
      "PUBLIC_URL=https://ci.acme.io",
      "TRUSTED_PROXIES=192.168.250.10",
      "STATIC_SITES_HOST=acme-sites.com",
    ] : contains(docker_container.circi.env, e)])
    error_message = "Caddy's settings: ${join(", ", docker_container.circi.env)}"
  }
  assert {
    condition     = one(docker_container.caddy[0].networks_advanced).ipv4_address == "192.168.250.10"
    error_message = "Caddy sits at the address the app trusts."
  }
  assert {
    condition     = !issensitive(docker_container.caddy[0].env) && length([for e in docker_container.caddy[0].env : e if strcontains(e, "route53-secret")]) == 0
    error_message = "Route53 keys stay out of Caddy's environment and the plan."
  }
  assert {
    condition     = length(docker_container.circi.ports) == 0
    error_message = "With Caddy, the app isn't published."
  }
}

run "caddy_owns_trusted_proxies" {
  command = plan

  variables {
    caddy           = { dashboard_host = "ci.acme.io", sites_host = "acme-sites.com" }
    trusted_proxies = ["10.0.0.0/8"]
  }

  expect_failures = [docker_container.circi]
}

# Every variable set to a value of its own: each must reach the server under its own name, a secret
# as a file. packages/config/test/deploy-settings.test.ts checks that every setting is listed here.
run "every_setting_reaches_the_server_under_its_name" {
  command = plan

  variables {
    public_url           = "https://ci.acme.io"
    previous_public_urls = ["https://old.acme.io"]
    trusted_proxies      = ["10.0.0.1"]
    log_level            = "warn"
    workspace_creation   = "anyone"
    s3 = {
      bucket                  = "bucket"
      region                  = "eu-west-3"
      endpoint                = "https://s3.example"
      force_path_style        = true
      access_key_id           = "s3-key-id"
      connect_timeout_seconds = 11
      request_timeout_seconds = 61
    }
    s3_secret_access_key = "s3-secret"
    smtp = {
      host   = "smtp.example"
      port   = 2525
      secure = false
      user   = "smtp-user"
      from   = "ci@acme.io"
    }
    smtp_password = "smtp-password"
    sign_in       = { email = false, password = false, sso = true }
    sso = {
      github_client_id       = "gh-id"
      google_client_id       = "google-id"
      gitlab_client_id       = "gitlab-id"
      gitlab_url             = "https://gitlab.acme.io"
      oidc_issuer            = "https://sso.acme.io"
      oidc_client_id         = "oidc-id"
      oidc_name              = "Acme SSO"
      oidc_trusted_for_email = true
    }
    auth_github_client_secret = "gh-secret"
    auth_google_client_secret = "google-secret"
    auth_gitlab_client_secret = "gitlab-secret"
    auth_oidc_client_secret   = "oidc-secret"
    github_app = {
      id                  = "42"
      api_url             = "https://ghe.acme.io/api/v3"
      api_timeout_seconds = 16
    }
    github_app_private_key    = "pem"
    github_app_webhook_secret = "hook-secret"
    slack                     = { client_id = "slack-id", api_url = "https://slack.example/api" }
    slack_client_secret       = "slack-secret"
    vapid                     = { public_key = "vapid-public", subject = "mailto:ops@acme.io" }
    vapid_private_key         = "vapid-private"
    sites                     = { host = "acme-sites.com", max_mb = 201 }
    jobs = {
      upload_timeout_minutes = 61
      gc_grace_hours         = 25
      retention_days         = 15
      retry_base_seconds     = 3
      retry_max_seconds      = 301
    }
    webhooks = { timeout_seconds = 12, allow_private_addresses = true }
    tuning = {
      database_pool_max = 21
      diff_engine       = "js-workers"
      diff_threads      = 3
      live_max_streams  = 2001
    }
  }


  assert {
    condition = toset(docker_container.circi.env) == toset([
      "PUBLIC_URL=https://ci.acme.io",
      "PREVIOUS_PUBLIC_URLS=https://old.acme.io",
      "TRUSTED_PROXIES=10.0.0.1",
      "STATIC_SITES_HOST=acme-sites.com",
      "LOG_LEVEL=warn",
      "DATABASE_POOL_MAX=21",
      "STORAGE_DRIVER=s3",
      "S3_BUCKET=bucket",
      "S3_REGION=eu-west-3",
      "S3_ENDPOINT=https://s3.example",
      "S3_FORCE_PATH_STYLE=true",
      "S3_ACCESS_KEY_ID=s3-key-id",
      "S3_CONNECT_TIMEOUT_SECONDS=11",
      "S3_REQUEST_TIMEOUT_SECONDS=61",
      "SMTP_HOST=smtp.example",
      "SMTP_PORT=2525",
      "SMTP_SECURE=false",
      "SMTP_USER=smtp-user",
      "SMTP_FROM=ci@acme.io",
      "AUTH_EMAIL_ENABLED=false",
      "AUTH_PASSWORD_ENABLED=false",
      "AUTH_SSO_ENABLED=true",
      "AUTH_GITHUB_CLIENT_ID=gh-id",
      "AUTH_GOOGLE_CLIENT_ID=google-id",
      "AUTH_GITLAB_CLIENT_ID=gitlab-id",
      "AUTH_GITLAB_URL=https://gitlab.acme.io",
      "AUTH_OIDC_ISSUER=https://sso.acme.io",
      "AUTH_OIDC_CLIENT_ID=oidc-id",
      "AUTH_OIDC_NAME=Acme SSO",
      "AUTH_OIDC_TRUSTED_FOR_EMAIL=true",
      "WORKSPACE_CREATION=anyone",
      "GITHUB_APP_ID=42",
      "GITHUB_API_URL=https://ghe.acme.io/api/v3",
      "GITHUB_API_TIMEOUT_SECONDS=16",
      "SLACK_CLIENT_ID=slack-id",
      "SLACK_API_URL=https://slack.example/api",
      "VAPID_PUBLIC_KEY=vapid-public",
      "VAPID_SUBJECT=mailto:ops@acme.io",
      "STATIC_SITES_MAX_MB=201",
      "UPLOAD_TIMEOUT_MINUTES=61",
      "GC_GRACE_HOURS=25",
      "JOB_RETENTION_DAYS=15",
      "JOB_RETRY_BASE_SECONDS=3",
      "JOB_RETRY_MAX_SECONDS=301",
      "WEBHOOK_TIMEOUT_SECONDS=12",
      "WEBHOOK_ALLOW_PRIVATE_ADDRESSES=true",
      "LIVE_MAX_STREAMS=2001",
      "CIRCI_DIFF_ENGINE=js-workers",
      "CIRCI_DIFF_THREADS=3",
      "BETTER_AUTH_SECRET_FILE=/run/circi/secrets/BETTER_AUTH_SECRET",
      "DATABASE_URL_FILE=/run/circi/secrets/DATABASE_URL",
      "S3_SECRET_ACCESS_KEY_FILE=/run/circi/secrets/S3_SECRET_ACCESS_KEY",
      "SMTP_PASSWORD_FILE=/run/circi/secrets/SMTP_PASSWORD",
      "AUTH_GITHUB_CLIENT_SECRET_FILE=/run/circi/secrets/AUTH_GITHUB_CLIENT_SECRET",
      "AUTH_GOOGLE_CLIENT_SECRET_FILE=/run/circi/secrets/AUTH_GOOGLE_CLIENT_SECRET",
      "AUTH_GITLAB_CLIENT_SECRET_FILE=/run/circi/secrets/AUTH_GITLAB_CLIENT_SECRET",
      "AUTH_OIDC_CLIENT_SECRET_FILE=/run/circi/secrets/AUTH_OIDC_CLIENT_SECRET",
      "GITHUB_APP_PRIVATE_KEY_FILE=/run/circi/secrets/GITHUB_APP_PRIVATE_KEY",
      "GITHUB_APP_WEBHOOK_SECRET_FILE=/run/circi/secrets/GITHUB_APP_WEBHOOK_SECRET",
      "SLACK_CLIENT_SECRET_FILE=/run/circi/secrets/SLACK_CLIENT_SECRET",
      "VAPID_PRIVATE_KEY_FILE=/run/circi/secrets/VAPID_PRIVATE_KEY",
    ])
    error_message = "Each setting under its own name: ${join(", ", sort(docker_container.circi.env))}"
  }
  assert {
    condition = nonsensitive({ for u in docker_container.circi.upload : trimprefix(u.file, "/run/circi/secrets/") => u.content if startswith(u.file, "/run/circi/secrets/") && u.file != "/run/circi/secrets/DATABASE_URL" }) == {
      BETTER_AUTH_SECRET        = "a-secret-that-is-at-least-32-characters-long"
      S3_SECRET_ACCESS_KEY      = "s3-secret"
      SMTP_PASSWORD             = "smtp-password"
      AUTH_GITHUB_CLIENT_SECRET = "gh-secret"
      AUTH_GOOGLE_CLIENT_SECRET = "google-secret"
      AUTH_GITLAB_CLIENT_SECRET = "gitlab-secret"
      AUTH_OIDC_CLIENT_SECRET   = "oidc-secret"
      GITHUB_APP_PRIVATE_KEY    = "pem"
      GITHUB_APP_WEBHOOK_SECRET = "hook-secret"
      SLACK_CLIENT_SECRET       = "slack-secret"
      VAPID_PRIVATE_KEY         = "vapid-private"
    }
    error_message = "Each secret's file holds its own variable's value."
  }
}

run "a_misspelled_key_fails_the_plan" {
  command = plan

  variables {
    smtp     = { hots = "smtp.acme.io" }
    database = { host = "db", user = "ci", passwrod = "x" }
  }

  expect_failures = [var.smtp, var.database]
}

run "a_value_of_the_wrong_type_fails_the_plan" {
  command = plan

  variables {
    smtp   = { port = "twenty-five" }
    s3     = { bucket = "b", force_path_style = "maybe" }
    tuning = { diff_engine = "rust" }
  }

  expect_failures = [var.smtp, var.s3, var.tuning]
}
