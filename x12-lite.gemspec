# encoding: utf-8

Gem::Specification.new do |s|
  s.name        = "x12-lite"
  s.version     = `grep -m 1 '^\s*VERSION' lib/x12-lite.rb | head -1 | cut -f 2 -d '"'`
  s.author      = "Steve Shreeve"
  s.email       = "steve.shreeve@gmail.com"
  s.summary     =  "A " +
  s.description = "Ruby gem to parse and generate X.12 transactions"
  s.homepage    = "https://github.com/shreeve/x12-lite"
  s.license     = "MIT"
  s.platform    = Gem::Platform::RUBY
  s.files       = `git ls-files`.split("\n") - %w[.gitignore]
  s.executables = `cd bin && git ls-files .`.split("\n")
  s.required_ruby_version = Gem::Requirement.new(">= 3.0") if s.respond_to? :required_ruby_version=
end
