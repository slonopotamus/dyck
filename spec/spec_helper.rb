# frozen_string_literal: true

require 'dyck'

RSpec.configure do |_config|
  def fixtures_dir
    Pathname.new(__dir__).join 'fixtures'
  end

  def fixture_file(*path)
    fixtures_dir.join(*path)
  end

  def read_fixture_idx(name)
    idx_dir = fixtures_dir.join('idx', name)
    records = (Dir.entries(idx_dir) - %w[. ..]).sort.map do |f|
      content = IO.read(idx_dir.join(f), mode: 'rb')
      Dyck::PalmDBRecord.new(content: content)
    end
    Dyck::Index.read(records, name)
  end
end
