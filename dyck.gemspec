# frozen_string_literal: true

require_relative 'lib/dyck/version'

Gem::Specification.new do |s|
  s.name = 'dyck'
  s.version = Dyck::VERSION
  s.authors = ['Marat Radchenko']
  s.email = ['marat@slonopotamus.org']
  s.summary = 'Mobi parser/generator library'
  s.homepage = 'https://github.com/slonopotamus/dyck'
  s.license = 'MIT'
  s.required_ruby_version = '>= 2.4.0'

  s.files = `git ls-files`.split("\n").reject { |f| f.match(%r{^spec/}) }
  s.executables = `git ls-files -- bin/*`.split("\n").map do |f|
    File.basename(f)
  end
  s.require_paths = ['lib']

  s.add_development_dependency 'rake', '~> 13.0.0'
  s.add_development_dependency 'rspec', '~> 3.10.0'
  s.add_development_dependency 'rubocop', '~> 1.11.0'
  s.add_development_dependency 'rubocop-rake', '~> 0.5.0'
  s.add_development_dependency 'rubocop-rspec', '~> 2.2.0'
end
