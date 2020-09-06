# frozen_string_literal: true

module Dyck
  # A single data record within PalmDB file
  class PalmDBRecord
    attr_accessor(:attributes)
    attr_accessor(:uid)
    attr_accessor(:body)

    def initialize(attributes: 0, uid: 0, body: '')
      @attributes = attributes
      @uid = uid
      @body = body
    end
  end

  # Represents a single PalmDB file
  class PalmDB # rubocop:disable Metrics/ClassLength
    # Max name length, including null terminating character
    NAME_LEN = 32
    TYPE_LEN = 4
    CREATOR_LEN = 4
    PALMDB_HEADER = %(A#{NAME_LEN}nnNNNNNNa#{TYPE_LEN}a#{CREATOR_LEN}NNn)

    # @return [String]
    attr_accessor(:name)
    attr_accessor(:attributes)
    attr_accessor(:version)
    # @return [Time]
    attr_accessor(:ctime)
    # @return [Time]
    attr_accessor(:mtime)
    # @return [Time]
    attr_accessor(:btime)
    attr_accessor(:mod_num)
    attr_accessor(:appinfo_offset)
    attr_accessor(:sortinfo_offset)
    # @return [String]
    attr_reader(:type)
    # @return [String]
    attr_reader(:creator)
    attr_accessor(:uid)
    attr_accessor(:next_rec)
    # @return [Array<Dyck::PalmDBRecord>]
    attr_reader(:records)

    # @param name [String]
    # @param ctime [Time]
    # @param mtime [Time]
    # @param btime [Time]
    def initialize( # rubocop:disable Metrics/MethodLength, Metrics/ParameterLists
      name: '', attributes: 0, version: 0, ctime: Time.now.utc, mtime: Time.now.utc, btime: Time.at(0).utc, mod_num: 0,
      appinfo_offset: 0, sortinfo_offset: 0, type: "\0\0\0\0".b, creator: "\0\0\0\0".b, uid: 0, next_rec: 0, records: []
    )
      @name = name
      @attributes = attributes
      @version = version
      @ctime = ctime.round
      @mtime = mtime.round
      @btime = btime.round
      @mod_num = mod_num
      @appinfo_offset = appinfo_offset
      @sortinfo_offset = sortinfo_offset
      @type = type
      @creator = creator
      @uid = uid
      @next_rec = next_rec
      @records = records
    end

    class << self
      # @return [Dyck::PalmDB]
      def read(filename_or_io)
        if filename_or_io.respond_to? :seek
          read_io(filename_or_io)
        else
          File.open(filename_or_io, 'rb') do |io|
            read_io(io)
          end
        end
      end

      private

      # @param io [IO]
      # @return [Dyck::PalmDB]
      def read_io(io) # rubocop:disable Metrics/AbcSize
        name, attributes, version, ctime, mtime, btime, mod_num, appinfo_offset, sortinfo_offset, type, creator, uid,
            next_rec, record_count = io.read(78).unpack(PALMDB_HEADER)
        result = PalmDB.new(
          name: name.encode('UTF-8'), attributes: attributes, version: version, ctime: Time.at(ctime).utc,
          mtime: Time.at(mtime).utc, btime: Time.at(btime).utc, mod_num: mod_num, appinfo_offset: appinfo_offset,
          sortinfo_offset: sortinfo_offset, type: type, creator: creator, uid: uid, next_rec: next_rec
        )
        read_records(result, io, record_count)
        result
      end

      def read_records(result, io, record_count) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        record_offsets = []
        (0..record_count - 1).each do |index|
          record_offsets[index], attributes, uid_high, uid_low = io.read(8).unpack('NCCn')
          result.records << PalmDBRecord.new(attributes: attributes, uid: uid_high | uid_low)
        end
        io.seek(0, IO::SEEK_END)
        eof = io.tell
        result.records.each_with_index do |record, index|
          io.seek(record_offsets[index])
          end_offset = index < record_offsets.size - 1 ? record_offsets[index + 1] : eof
          record.body = io.read(end_offset - record_offsets[index])
        end
      end
    end

    def write(filename_or_io)
      if filename_or_io.respond_to? :write
        write_io(filename_or_io)
      else
        File.open(filename_or_io, 'wb') do |io|
          write_io(io)
        end
      end
    end

    private

    def write_io(io)
      io.binmode
      io.write([
        @name, @attributes, @version, @ctime.to_i, @mtime.to_i, @btime.to_i, @mod_num, @appinfo_offset,
        @sortinfo_offset, @type, @creator, @uid, @next_rec, @records.size
      ].pack(PALMDB_HEADER))
      write_records(io)
    end

    def write_records(io) # rubocop:disable Metrics/AbcSize
      # Write record headers
      offset = io.tell + 8 * @records.size
      @records.each do |record|
        io.write([offset, record.attributes, record.uid >> 16, record.uid & 0xFF].pack('NCCn'))
        offset += record.body.bytesize
      end
      # Write record bodies
      @records.each do |record|
        io.write(record.body)
      end
      io
    end
  end
end
