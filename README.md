# capistrano-nomad

Capistrano plugin for deploying and managing [Nomad](http://nomadproject.io) jobs

## Installation

Add this line to your application's Gemfile:

```ruby
gem "capistrano-nomad"
```

And then execute:

```shell
bundle install
```

Or install it yourself as:

```shell
gem install capistrano-nomad
```

## Usage

Add to `Capfile`

```ruby
require "capistrano/nomad"
install_plugin Capistrano::Nomad
```

Within `deploy.rb`

```ruby
set :nomad_jobs_path, "nomad/jobs"
set :nomad_var_files_path, "nomad/vars"

# Determines base URL to use when opening job in web UI
set :nomad_ui_url, "http://localhost:4646"

# Make variables available to all template .erb files
set :nomad_template_vars, (lambda do
  {
    env_name: fetch(:stage).to_sym,
    domain: fetch(:domain),
    foo: "bar,"
  }
end)

# Change docker build command
set :nomad_docker_build_command, (lambda do
  "docker buildx build"
end)

# Pass additional options into `docker build`
set :nomad_docker_build_command_options, (lambda do
  [
    "--cache-to type=gha",
    "--cache-from type=gha",
  ]
end)

# Make helpers available to all template .erb files
nomad_template_helpers do
  def restart_stanza(interval = "1m")
    <<-EOF
      restart {
        interval = "#{interval}"
        attempts = 3
        mode = "delay"
      }
    EOF
  end
end

# Use hosted Docker image
nomad_docker_image_type :postgres,
  alias: "postgres:5.0.0"

# Use Docker image that will be built locally relative to project and push
nomad_docker_image_type :backend,
  path: "local/path/backend",
  alias: ->(image_type:) { "gcr.io/axsuul/#{image_type}" },
  target: "release",
  build_args: { foo: "bar" }

# Use Docker image that will be built locally from an absolute path and push
nomad_docker_image_type :redis,
  path: "/absolute/path/redis",
  alias: "gcr.io/axsuul/redis"

# Use Docker image that will be built remotely on server
nomad_docker_image_type :restic,
  path: "containers/restic",
  alias: "my-project/restic:local",
  strategy: :remote_build

# Jobs
nomad_job :backend, docker_image_types: [:backend], var_files: [:rails]
nomad_job :frontend
nomad_job :postgres, docker_image_types: [:postgres]
nomad_job :redis, docker_image_types: [:redis], tags: [:redis]
nomad_job :"traefik-default", template: :admin,
  erb_vars: { role: :default },
  tags: [:traefik]
nomad_job :"traefik-secondary", template: :admin,
  erb_vars: { role: :secondary },
  tags: [:traefik]

nomad_namespace :analytics, tags: [:admin] do
  nomad_job :grafana
end

nomad_namespace :maintenance, path: "maintenance-stuff" do
  nomad_job :garbage_collection
end
```

Deploy individual jobs

```shell
cap production nomad:app:deploy
cap production nomad:analytics:grafana:deploy
```

Manage jobs

```shell
cap production nomad:app:stop
cap production nomad:redis:purge
cap production nomad:analytics:grafana:restart
cap production nomad:postgres:status
```

Tasks can apply across all namespaces or be filtered by namespaces or tags

```shell
cap production nomad:analytics:deploy
cap production nomad:analytics:upload_run
cap production nomad:deploy
cap production nomad:deploy TAG=admin
cap production nomad:upload_run
cap production nomad:upload_run TAGS=admin,redis
```

Open console

```shell
cap production nomad:app:console
cap production nomad:app:console TASK=custom-task-name
cap production nomad:analytics:grafana:console
```

Display logs

```shell
cap production nomad:app:logs
cap production nomad:app:stdout
cap production nomad:app:stderr
cap production nomad:analytics:grafana:follow
```

Revert jobs

```shell
cap production nomad:app:revert
cap production nomad:app:revert VERSION=4
cap production nomad:app:revert DOCKER_IMAGE=v1.4.4
```

Open job in web UI

```shell
cap production nomad:app:ui
```

Create missing and delete unused namespaces

```shell
cap production nomad:modify_namespaces
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/axsuul/capistrano-nomad.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
