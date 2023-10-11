require "capistrano/scm/plugin"
require_relative "../helpers/git"

class Capistrano::SCM::GitLocal < Capistrano::SCM::Plugin
  def define_tasks
    namespace :git_local do
      task :set_current_revision do
        on release_roles :manager do
          set :current_revision, capistrano_nomad_git_commit_id
        end
      end

      task :create_release do
        on release_roles :manager do
          execute :mkdir, "-p", release_path
        end
      end
    end
  end

  def register_hooks
    before "deploy:set_current_revision", "git_local:set_current_revision"
    after "deploy:new_release_path", "git_local:create_release"
  end
end
