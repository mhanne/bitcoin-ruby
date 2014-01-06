[
# "2fd4aa6f88e9a0e94bc3191097eabdca7e2bc46a",
# "a37c84daef707bed59ab986e7e4376b7c3780aec",
# "1aa182078d6bb410120e77bc320244aab616b6fb",
# "3fabf27194dfac2b19711f3eb5d9f5410a2306de",
# "b33f46d0a0af921f78094c0c3cb9d3c7cdd46512",
# "0e0688c6b1f94124eeb48fdf2b771ee03e7d7dc5",

# "54e9f9651647325354964e15f7d70a342f8fba73",
# "fc2fc65cdd67b626344fb24c6e702670ac5907ad",
# "33c6e1f0aeb75eb0087c270b6862d45f154d7353",

# "185321af961c8b468e798d272bc10a95ff6e12ba",
# "1d4b174c19942d3ca17bec84b2639fae7ff2a302",
# "76aea5ee656b670dfe68bb96398bf09d7828e3cc",

# "cbb4d3b6736da4fcbfddae77581e79e55025eaa2",

"v0.0.2", "v0.0.3", "v0.0.4", "v0.0.5", 
"comboy/sequel_copy_into",
"comboy/validation_optimization",
"comboy/store_block_optimizations",
"comboy/check_spent_in_current_block",
"comboy/validation_optimizations2",
"master"
].each do |rev|
  puts "Running benchmarks for revision #{rev}"
  `cp examples/benchmark.rb examples/benchmark.rb.bak`
  `cp spec/bitcoin/helpers/fake_blockchain.rb spec/bitcoin/helpers/fake_blockchain.rb.bak`
  `git checkout -f #{rev}`
  `cp examples/benchmark.rb.bak examples/benchmark.rb`
  `cp spec/bitcoin/helpers/fake_blockchain.rb.bak spec/bitcoin/helpers/fake_blockchain.rb`

  system("ruby examples/benchmark.rb #{rev}")
end
