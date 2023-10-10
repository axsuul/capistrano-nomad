def capistrano_nomad_root
  @capistrano_nomad_root ||= Pathname.new(fetch(:root) || "")
end

def capistrano_nomad_deep_symbolize_hash_keys(hash)
  JSON.parse(JSON[hash], symbolize_names: true)
end
