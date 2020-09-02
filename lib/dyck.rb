# frozen_string_literal: true

require 'dyck/version'

module Dyck
  # Represents a single Mobi file
  class Mobi # rubocop:disable Metrics/ClassLength
    # Max name length, without null terminating character
    NAME_LEN = 31

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
    attr_accessor(:rec_count)

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
      rec_count: 0
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
      @rec_count = rec_count
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
        Mobi.new(
          name: io.read(NAME_LEN + 1).unpack1('Z*').encode('UTF-8'),
          attributes: io.read(2).unpack1('n'),
          version: io.read(2).unpack1('n'),
          ctime: Time.at(io.read(4).unpack1('N')).utc,
          mtime: Time.at(io.read(4).unpack1('N')).utc,
          btime: Time.at(io.read(4).unpack1('N')).utc,
          mod_num: io.read(4).unpack1('N'),
          appinfo_offset: io.read(4).unpack1('N'),
          sortinfo_offset: io.read(4).unpack1('N'),
          type: io.read(4).encode('UTF-8'),
          creator: io.read(4).encode('UTF-8'),
          uid: io.read(4).unpack1('N'),
          next_rec: io.read(4).unpack1('N'),
          rec_count: io.read(2).unpack1('n')
        )
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
      io.write(@name.encode('ASCII')[0..NAME_LEN].ljust(NAME_LEN + 1, "\0"))
      io.write([@attributes].pack('n'))
      io.write([@version].pack('n'))
      io.write([@ctime.to_i].pack('N'))
      io.write([@mtime.to_i].pack('N'))
      io.write([@btime.to_i].pack('N'))
      io.write([@mod_num].pack('N'))
      io.write([@appinfo_offset].pack('N'))
      io.write([@sortinfo_offset].pack('N'))
      io.write(@type.encode('ASCII'))
      io.write(@creator.encode('ASCII'))
      io.write([@uid].pack('N'))
      io.write([@next_rec].pack('N'))
      io.write([@rec_count].pack('n'))
      io
    end
  end
end
