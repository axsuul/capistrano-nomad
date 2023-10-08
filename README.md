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

Define Nomad jobs within `deploy.rb`

```ruby
nomad_job :app
nomad_job :redis

nomad_namespace :analytics do
  nomad_job :grafana
end
```

Utilize tasks

```shell
cap production nomad:app:deploy
cap production nomad:redis:purge
cap production nomad:analytics:grafana:deploy
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/axsuul/capistrano-nomad.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
