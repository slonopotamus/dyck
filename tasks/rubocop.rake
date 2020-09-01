# frozen_string_literal: true

require 'rubocop/rake_task'

RuboCop::RakeTask.new :lint do |t|
  t.patterns = Dir['lib/*.rb'] + %w[Rakefile Gemfile tasks/*.rake spec/*.rb]
end
