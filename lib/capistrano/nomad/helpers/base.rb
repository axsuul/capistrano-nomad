def capistrano_nomad_deep_symbolize_hash_keys(hash)
  JSON.parse(JSON[hash], symbolize_names: true)
end
