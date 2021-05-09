# frozen_string_literal: true

require 'dyck'

RSpec.configure do |_config|
  # @return [Pathname]
  def fixtures_dir
    Pathname.new(__dir__).join('fixtures')
  end

  # @return [Pathname]
  def fixture_file(*path)
    fixtures_dir.join(*path)
  end

  # @param name [String]
  # @return [Array<Dyck::PalmDBRecord>]
  def read_fixture_index_records(name)
    idx_dir = fixtures_dir.join('idx', name)
    (Dir.entries(idx_dir) - %w[. ..]).sort.map do |f|
      content = IO.read(idx_dir.join(f), mode: 'rb')
      Dyck::PalmDBRecord.new(content: content)
    end
  end

  # @param name [String]
  # @return [Dyck::Index]
  def read_fixture_index(name)
    records = read_fixture_index_records(name)
    Dyck::Index.read(records, name)
  end
end
