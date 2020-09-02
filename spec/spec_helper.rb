# frozen_string_literal: true

require 'dyck'

RSpec.configure do |_config|
  def fixtures_dir
    Pathname.new(__dir__).join 'fixtures'
  end

  def fixture_file(*path)
    fixtures_dir.join(*path)
  end
end
