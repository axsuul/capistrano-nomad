require "capistrano/plugin"
require "byebug"
require_relative "nomad/helpers/base"
require_relative "nomad/helpers/docker"
require_relative "nomad/helpers/dsl"
require_relative "nomad/helpers/git"
require_relative "nomad/helpers/nomad"

module Capistrano
  class Nomad < Capistrano::Plugin
    def set_defaults
      set_if_empty(:nomad_jobs_path, "nomad/jobs")
      set_if_empty(:nomad_var_files_path, "nomad/var_files")
      set_if_empty(:nomad_ui_url, "http://localhost:4646")
      set_if_empty(:nomad_docker_image_alias, ->(**) {})
    end

    def define_tasks
      eval_rakefile(File.expand_path("nomad/tasks/nomad.rake", __dir__))
    end
  end
end
