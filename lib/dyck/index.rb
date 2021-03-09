# frozen_string_literal: true

require 'dyck/palmdb'

module Dyck
  # Key structure for tag values lookup
  class IndexTagKey
    # @return [Integer]
    attr_reader(:tag_id)
    # @return [Integer]
    attr_reader(:tag_index)

    def initialize(tag_id: 0, tag_index: 0)
      @tag_id = tag_id
      @tag_index = tag_index
    end
  end

  # A single entry in KF8 metadata index
  class IndexEntry
    # @return [String]
    attr_reader(:label)
    # @return [Hash<Integer, Integer>]
    attr_reader(:tags)

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

  # Tag info used to read/write tag values
  class Tagx
    # @return [Integer]
    attr_reader(:tag)
    # @return [Integer]
    attr_reader(:values_count)
    # @return [Integer]
    attr_reader(:bitmask)
    # @return [Integer]
    attr_reader(:shift)

    def initialize(tag: 0, values_count: 0, bitmask: 0, shift: 0)
      @tag = tag
      @values_count = values_count
      @bitmask = bitmask
      @shift = shift
    end
  end

  # KF8 metadata index
  class Index # rubocop:disable Metrics/ClassLength
    INDX_MAGIC = 'INDX'.b
    INDX_HEADER = %(A#{INDX_MAGIC.size}N*)
    INDX_HEADER_LENGTH = 7 * 4

    TAGX_MAGIC = 'TAGX'.b
    TAGX_HEADER = %(A#{TAGX_MAGIC.size}N*)

    IDXT_MAGIC = 'IDXT'.b
    IDXT_HEADER = %(A#{IDXT_MAGIC.size})
    IDXT_HEADER_SIZE = IDXT_MAGIC.bytesize

    # @return [String] only used for easier debugging, not saved to Mobi (yet)
    attr_reader(:name)
    # @return [Array<Dyck::IndexEntry>]
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
            shift = 0
            while (bitmask & 1).zero?
              shift += 1
              bitmask >>= 1
            end
            Tagx.new(tag: tag, values_count: values_count, bitmask: bitmask, shift: shift)
          end
          raise ArgumentError, %(Wrong count of control bytes) if tagx_control_byte_count != control_byte_count
          raise ArgumentError, %(Only control bytes = 1 is implemented) if control_byte_count != 1

          record_count = entries_count
        end

        (1..record_count).each do |record_idx|
          read_index_record(records[record_idx]) do |io, idxt_offset, entries_count|
            io.seek(idxt_offset)
            idxt_magic, = io.read(IDXT_HEADER_SIZE).unpack(IDXT_HEADER)
            raise ArgumentError, %(Unsupported IDXT magic: #{idxt_magic}) if idxt_magic != IDXT_MAGIC

            entry_offsets = entries_count.times.map do |_|
              io.read(2).unpack1('n')
            end
            result.entries.concat(entry_offsets.map do |entry_offset|
              io.seek(entry_offset)
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
        magic, header_length, _, _type, _, idxt_offset, entries_count = io.read(INDX_HEADER_LENGTH).unpack(INDX_HEADER)
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
        control_bytes = io.read(control_byte_count).unpack('C*')
        value_info = tags.map do |tagx|
          next if tagx.nil?

          value = tagx.bitmask & ((control_bytes[0] || 0) >> tagx.shift)
          next if value.zero?

          value_count = MOBI_NOTSET
          value_bytes = MOBI_NOTSET
          if value == tagx.bitmask && Dyck.popcount(tagx.bitmask) > 1
            # TODO: does this branch happen in the wild at all?
            value_bytes, consumed = Dyck.decode_varlen(io.string, io.tell)
            io.seek(consumed, IO::SEEK_CUR)
          else
            value_count = value
          end
          [tagx, value_bytes, value_count]
        end.compact

        tags_values = {}
        value_info.each do |tagx, value_bytes, value_count|
          if value_count != MOBI_NOTSET
            count = value_count * tagx.values_count
            values = count.times.map do |_|
              value, consumed = Dyck.decode_varlen(io.string, io.tell)
              io.seek(consumed, IO::SEEK_CUR)
              value
            end
          else
            total_consumed = 0
            values = []
            while total_consumed < value_bytes
              value, consumed = Dyck.decode_varlen(io.string, io.tell)
              io.seek(consumed, IO::SEEK_CUR)
              values << value
              total_consumed += consumed
            end
          end
          tags_values[tagx.tag] = values
        end
        IndexEntry.new(label: label, tags: tags_values)
      end
    end

    # @return [Array<Dyck::PalmDBRecord>]
    def write # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      records = [record = PalmDBRecord.new]
      header = PalmDBRecord.new

      shift = 0
      # TODO: build tag bitmasks from all entries in case they have different number of values
      tags = @entries[0]&.tags&.sort_by do |k, _|
        k
      end&.map do |tag, values|
        bitmask = 0
        val = values.size
        num_bits = 0
        until val.zero?
          bitmask <<= 1
          bitmask |= 1
          val >>= 1
          num_bits += 1
        end
        result = Tagx.new(tag: tag, values_count: values.size, bitmask: bitmask, shift: shift)
        shift += num_bits
        result
      end || []
      tagx_control_byte_count = 1
      tags += [nil] * tagx_control_byte_count

      entries_data = StringIO.new
      entries_data.binmode
      entry_start_offset = INDX_HEADER_LENGTH
      entries_offsets = @entries.map do |entry|
        bytes = write_index_entry(entry, tagx_control_byte_count, tags)
        entries_data.write(bytes)
        result = entry_start_offset
        entry_start_offset += bytes.bytesize
        result
      end
      idxt_offset = INDX_HEADER_LENGTH + entries_data.string.bytesize

      record.content = [INDX_MAGIC, INDX_HEADER_LENGTH, 0, 0, 0, idxt_offset, @entries.size].pack(INDX_HEADER)
      record.content += entries_data.string
      record.content += [IDXT_MAGIC].pack(IDXT_HEADER)
      record.content += entries_offsets.pack('n*')

      tagx_record_length = 12 + tags.size * 4

      header.content = [INDX_MAGIC, INDX_HEADER_LENGTH, 0, 0, 0, 0, records.size].pack(INDX_HEADER)
      header.content += [TAGX_MAGIC, tagx_record_length, tagx_control_byte_count].pack(TAGX_HEADER)
      tags.each do |tagx|
        tagx_data = tagx.nil? ? [0, 0, 0, 1] : [tagx.tag, tagx.values_count, tagx.bitmask << tagx.shift, 0]
        header.content += tagx_data.pack('C*')
      end

      [header] + records
    end

    # @param entry [Dyck::IndexEntry]
    # @param control_bytes_count [Integer]
    # @param tags [Array<Dyck::Tagx, nil>]
    # @return [String]
    def write_index_entry(entry, control_bytes_count, tags) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      io = StringIO.new
      io.binmode

      io.write([entry.label.bytesize].pack('C'))
      io.write(entry.label)

      control_byte = 0
      tags.each do |tagx|
        control_byte |= 1 << tagx.shift unless tagx.nil?
      end

      io.write(([control_byte] + [0] * (control_bytes_count - 1)).pack('C*'))
      tags.each do |tagx|
        next if tagx.nil?

        (0..tagx.values_count - 1).each do |val_idx|
          value = entry.tags[tagx.tag][val_idx]
          io.write(Dyck.encode_varlen(value))
        end
      end

      io.string
    end
  end
end
