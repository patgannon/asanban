# -*- encoding: utf-8 -*-
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'asanban/version'

Gem::Specification.new do |gem|
  gem.name          = "asanban"
  gem.version       = Asanban::VERSION
  gem.authors       = ["Pat Gannon"]
  gem.email         = ["gannon@bizo.com"]
  gem.description   = %q{Track Kanban metrics using Asana}
  gem.summary       = %q{Track Kanban metrics using Asana as a data source}
  gem.homepage      = "http://www.bizo.com"

  gem.files         = `git ls-files`.split($/)
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.require_paths = ["lib"]
  gem.license       = "ruby"
  gem.add_dependency "mongo"
  gem.add_dependency "json"
  gem.add_dependency "json_pure"
  gem.add_dependency "sinatra"
  gem.add_dependency "descriptive_statistics"
  gem.add_dependency "mail"
  gem.add_dependency "gmail_xoauth"
  gem.add_development_dependency "rspec"
  gem.add_development_dependency "rack-test"
end
