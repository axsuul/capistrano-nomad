## [Unreleased]

## [0.15.0]

- Fix command escaping for console task to support complex commands with special characters using base64 encoding

## [0.14.1]

- Support for `IS_DETACHED` environment variable to run jobs in detached mode (e.g. `IS_DETACHED=true cap production nomad:app:deploy`)

## [0.14.0]

- `nomad:deploy` properly deploys all jobs across all namespaces now

## [0.13.3]

- Support for namespace-level `erb_vars` that are passed to all jobs within that namespace

## [0.13.2]

- Add missing start job task

## [0.13.1]

- Support for starting jobs (e.g. `cap production nomad:app:start`)

## [0.13.0]

- Support for `NOMAD_TOKEN` environment variable authentication via `:nomad_token` configuration option

## [0.1.0] - 2023-09-09

- Initial release
