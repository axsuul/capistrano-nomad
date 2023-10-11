require "git"

def capistrano_nomad_git
  @capistrano_nomad_git ||= Git.open(".")
end

def capistrano_nomad_git_commit_id
  @capistrano_nomad_git_commit_id ||= capistrano_nomad_git.log.first.sha
end
