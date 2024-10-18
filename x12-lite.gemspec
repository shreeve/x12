# encoding: utf-8

Gem::Specification.new do |gem|
  gem.name        = "x12-lite"
  gem.version     = `grep -m 1 '^\s*VERSION' lib/x12-lite.rb | head -1 | cut -f 2 -d '"'`
  gem.author      = "Steve Shreeve"
  gem.email       = "steve.shreeve@gmail.com"
  gem.summary     =  "A " +
  gem.description = "Ruby gem to parse and generate X.12 transactions"
  gem.homepage    = "https://github.com/shreeve/x12-lite"
  gem.license     = "MIT"
  gem.platform    = Gem::Platform::RUBY
  gem.files       = `git ls-files`.split("\n") - %w[.gitignore]
  gem.executables = `cd bin && git ls-files .`.split("\n")
  gem.required_ruby_version = Gem::Requirement.new(">= 3.0") if gem.respond_to? :required_ruby_version=
# gem.add_dependency "nokogiri"
end
