# frozen_string_literal: true

require 'dyck/palmdb'

module Dyck
  IndexTagKey = Struct.new(:tag_id, :tag_index)

  # A single entry in KF8 metadata index
  class IndexEntry
    # @return [String]
    attr_accessor(:label)

    def initialize(label: ''.b, tags: {})
      @label = label
      @tags = tags
    end

    # @param tag_key [Dyck::IndexTagKey]
    def tag_value(tag_key)
      @tags[tag_key.tag_id][tag_key.tag_index]
    end

    # @param tag_key [Dyck::IndexTagKey]
    # @param value [Integer]
    def set_tag_value(tag_key, value)
      (@tags[tag_key.tag_id] ||= {})[tag_key.tag_index] = value
    end
  end

  # KF8 metadata index
  class Index # rubocop:disable Metrics/ClassLength
    INDX_MAGIC = 'INDX'.b
    INDX_HEADER = %(A#{INDX_MAGIC.size}N*)

    TAGX_MAGIC = 'TAGX'.b
    TAGX_HEADER = %(A#{TAGX_MAGIC.size}N*)

    IDXT_MAGIC = 'IDXT'.b

    Tagx = Struct.new(:tag, :values_count, :bitmask)

    # @return [String] only used for easier debugging, not saved to Mobi (yet)
    attr_reader(:name)
    # @return []Array<Dyck::IndexEntry>]
    attr_reader(:entries)

    def initialize(name)
      @name = name
      @entries = []
    end

    class << self
      # @param records [Array<Dyck::PalmDBRecord>]
      # @param name [String]
      # @return [Index, nil]
      def read(records, name) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        result = Index.new(name)

        tagx_control_byte_count = 0
        record_count = 0
        tags = []
        read_index_record(records[0]) do |io, _idxt_offset, entries_count|
          tagx_magic, tagx_record_length, tagx_control_byte_count = io.read(12).unpack(TAGX_HEADER)
          raise ArgumentError, %(Unsupported TAGX magic: #{tagx_magic}) if tagx_magic != TAGX_MAGIC

          tagx_data_length = (tagx_record_length - 12) / 4
          control_byte_count = 0
          tags = tagx_data_length.times.map do |_|
            tag, values_count, bitmask, control_byte = io.read(4).unpack('C*')
            if control_byte != 0
              control_byte_count += 1
              next
            end
            Tagx.new(tag, values_count, bitmask)
          end
          raise ArgumentError, %(Wrong count of control bytes) if tagx_control_byte_count != control_byte_count

          record_count = entries_count
        end

        (1..record_count).each do |record_idx|
          read_index_record(records[record_idx]) do |io, idxt_offset, entries_count|
            io.seek(idxt_offset)
            idxt_magic = io.read(4)
            raise ArgumentError, %(Unsupported IDXT magic: #{idxt_magic}) if idxt_magic != IDXT_MAGIC

            offsets = (0..entries_count).map do |entry_idx|
              # last entry end position is IDXT tag offset
              entry_idx < entries_count ? io.read(2).unpack1('n') : idxt_offset
            end
            result.entries.concat((0..entries_count - 1).map do |entry_idx|
              io.seek(offsets[entry_idx])
              read_index_entry(io, tags, tagx_control_byte_count)
            end)
          end
        end
        result
      end

      private

      # @param record [Dyck::PalmDBRecord]
      def read_index_record(record)
        io = StringIO.new(record.content)
        magic, header_length, _, _type, _, idxt_offset, entries_count = io.read(7 * 4).unpack(INDX_HEADER)
        raise ArgumentError, %(Unsupported INDX magic: #{magic}) if magic != INDX_MAGIC

        io.seek(header_length)

        yield io, idxt_offset, entries_count
      end

      # @param io [StringIO]
      # @param control_byte_count [Number]
      # @param tags [Array<Dyck::Index::Tagx>]
      # @return [Dyck::IndexEntry]
      def read_index_entry(io, tags, control_byte_count) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        label_length = io.read(1).unpack1('C')
        label = io.read(label_length)
        control_bytes = io.read(control_byte_count).unpack('C')
        value_info = tags.map do |tagx|
          if tagx.nil?
            control_bytes.shift
            next
          end

          value = control_bytes[0] & tagx.bitmask
          next unless value != 0

          value_count = MOBI_NOTSET
          value_bytes = MOBI_NOTSET
          if value == tagx.bitmask
            if Dyck.popcount(tagx.bitmask) > 1
              value_bytes, consumed = Dyck.get_varlen(io.string, io.tell)
              io.seek(consumed, IO::SEEK_CUR)
            else
              value_count = 1
            end
          else
            mask = tagx.bitmask
            while (mask & 1).zero?
              mask >>= 1
              value >>= 1
            end
            value_count = value
          end
          [tagx, value_bytes, value_count]
        end.compact

        tags = {}
        value_info.each do |tagx, value_bytes, value_count|
          if value_count != MOBI_NOTSET
            count = value_count * tagx.values_count
            values = count.times.map do |_|
              value, consumed = Dyck.get_varlen(io.string, io.tell)
              io.seek(consumed, IO::SEEK_CUR)
              value
            end
          else
            total_consumed = 0
            values = []
            while total_consumed < value_bytes
              value, consumed = Dyck.get_varlen(io.string, io.tell)
              io.seek(consumed, IO::SEEK_CUR)
              values << value
              total_consumed += consumed
            end
          end
          tags[tagx.tag] = values
        end
        IndexEntry.new(label: label, tags: tags)
      end
    end

    # @return [Array<Dyck::PalmDBRecord>]
    def write
      result = [header = PalmDBRecord.new]
      header_length = 7 * 4
      idxt_offset = 0
      record_count = 0
      header.content = [INDX_MAGIC, header_length, 0, 0, 0, idxt_offset, record_count].pack(INDX_HEADER)

      tagx_record_length = 0
      tagx_control_byte_count = 0
      header.content += [TAGX_MAGIC, tagx_record_length, tagx_control_byte_count].pack(TAGX_HEADER)

      result
    end
  end
end
