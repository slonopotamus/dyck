# frozen_string_literal: true

require 'dyck/version'

module Dyck
  # A single record within Mobi file
  class MobiRecord
    attr_accessor(:attributes)
    attr_accessor(:uid)
    attr_accessor(:body)

    def initialize(attributes: 0, uid: 0, body: '')
      @attributes = attributes
      @uid = uid
      @body = body
    end
  end

  # Represents a single Mobi file
  class Mobi # rubocop:disable Metrics/ClassLength
    # Max name length, including null terminating character
    NAME_LEN = 32
    TYPE_LEN = 4
    CREATOR_LEN = 4

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
    # @return [Array<Dyck::MobiRecord>]
    attr_reader(:records)

    # @param name [String]
    # @param ctime [Time]
    # @param mtime [Time]
    # @param btime [Time]
    def initialize( # rubocop:disable Metrics/MethodLength, Metrics/ParameterLists
      name: '',
      attributes: 0,
      version: 0,
      ctime: Time.now.utc,
      mtime: Time.now.utc,
      btime: Time.at(0).utc,
      mod_num: 0,
      appinfo_offset: 0,
      sortinfo_offset: 0,
      type: 'BOOK',
      creator: 'MOBI',
      uid: 0,
      next_rec: 0,
      records: []
    )
      raise ArgumentError, %(Unsupported file type: #{type}) if type != 'BOOK'

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
      # @return [Dyck::Mobi]
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
      # @return [Dyck::Mobi]
      def read_io(io) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        mobi = Mobi.new(
          name: io.read(NAME_LEN).unpack1('Z*').encode('UTF-8'),
          attributes: io.read(2).unpack1('n'),
          version: io.read(2).unpack1('n'),
          ctime: Time.at(io.read(4).unpack1('N')).utc,
          mtime: Time.at(io.read(4).unpack1('N')).utc,
          btime: Time.at(io.read(4).unpack1('N')).utc,
          mod_num: io.read(4).unpack1('N'),
          appinfo_offset: io.read(4).unpack1('N'),
          sortinfo_offset: io.read(4).unpack1('N'),
          type: io.read(TYPE_LEN).unpack1('Z*').encode('UTF-8'),
          creator: io.read(CREATOR_LEN).unpack1('Z*').encode('UTF-8'),
          uid: io.read(4).unpack1('N'),
          next_rec: io.read(4).unpack1('N')
        )

        read_records(io, mobi)
      end

      def read_records(io, mobi) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
        record_count = io.read(2).unpack1('n')
        record_offsets = []
        (0..record_count - 1).each do |_|
          record_offsets << io.read(4).unpack1('N')
          mobi.records << MobiRecord.new(
            attributes: io.read(1).unpack1('C'),
            uid: io.read(1).unpack1('C') << 16 | io.read(2).unpack1('n')
          )
        end
        io.seek(0, IO::SEEK_END)
        eof = io.tell
        mobi.records.each_with_index do |record, index|
          io.seek(record_offsets[index])
          end_offset = index < record_offsets.size - 1 ? record_offsets[index + 1] : eof
          record.body = io.read(end_offset - record_offsets[index])
        end
        mobi
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

    def write_io(io) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      io.write(@name.encode('ASCII')[0..NAME_LEN - 2].ljust(NAME_LEN, "\0"))
      io.write([@attributes].pack('n'))
      io.write([@version].pack('n'))
      io.write([@ctime.to_i].pack('N'))
      io.write([@mtime.to_i].pack('N'))
      io.write([@btime.to_i].pack('N'))
      io.write([@mod_num].pack('N'))
      io.write([@appinfo_offset].pack('N'))
      io.write([@sortinfo_offset].pack('N'))
      io.write(@type.encode('ASCII')[0..TYPE_LEN - 1].ljust(TYPE_LEN, "\0"))
      io.write(@creator.encode('ASCII')[0..CREATOR_LEN - 1].ljust(CREATOR_LEN, "\0"))
      io.write([@uid].pack('N'))
      io.write([@next_rec].pack('N'))
      write_records(io)
    end

    def write_records(io) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
      io.write([@records.size].pack('n'))
      # Write record headers
      offset = io.tell + 8 * @records.size
      @records.each do |record|
        io.write([offset].pack('N'))
        io.write([record.attributes].pack('C'))
        io.write([record.uid >> 16].pack('C'))
        io.write([record.uid & 0xFF].pack('n'))
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
