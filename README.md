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

# Docker image types
nomad_docker_image_type :app,
  path: "backend",
  alias: ->(image_type:) { "gcr.io/axsuul/#{image_type}" },
  target: "release",
  build_args: { foo: "bar" }
nomad_docker_image_type :redis,
  path: "/absolute/path/redis",
  alias: "gcr.io/axsuul/redis"

# Jobs
nomad_job :app
nomad_job :redis, docker_image_types: [:redis]

nomad_namespace :analytics do
  nomad_job :grafana
end
```

Deploy all with

```shell
cap production nomad:all:deploy
```

Deploy individually with

```shell
cap production nomad:app:deploy
cap production nomad:redis:purge
cap production nomad:analytics:grafana:deploy
```

Open console with

```shell
cap production nomad:app:console
cap production nomad:app:console TASK=custom-task-name
cap production nomad:analytics:grafana:console
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/axsuul/capistrano-nomad.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
