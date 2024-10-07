#!/usr/bin/env ruby

# ==============================================================================
# x12.rb: X12 library for Ruby
#
# Author: Steve Shreeve <steve.shreeve@trusthealth.com>
#   Date: October 7, 2024
#
#  Legal: All rights reserved.
# ==============================================================================

require "enumerator"
require "find"

class Object
  def blank?
    respond_to?(:empty?) or return !self
    empty? or respond_to?(:strip) && strip.empty?
  end unless defined? blank?
end

# ==[ ANSI colors ]=============================================================

def hex(str=nil)
  ($hex ||= {})[str] ||= begin
    str =~ /\A#?(?:(\h\h)(\h\h)(\h\h)|(\h)(\h)(\h))\z/ or return
    r, g, b = $1 ? [$1, $2, $3] : [$4*2, $5*2, $6*2]
    [r.hex, g.hex, b.hex] * ";"
  end
end

def fg(rgb=nil); rgb ? "\e[38;2;#{hex(rgb)}m" : "\e[39m"; end
def bg(rgb=nil); rgb ? "\e[48;2;#{hex(rgb)}m" : "\e[49m"; end

def ansi(str, f=nil, b=nil)
  [
    (fg(f) if f),
    (bg(b) if b),
    str,
    (bg    if b),
    (fg    if f),
  ].compact.join
end

# ==[ X12 ]=====================================================================

class X12
  VERSION="0.1.0"

  include Enumerable

  # ISA field widths
  LEN = [3, 2, 10, 2, 10, 2, 15, 2, 15, 6, 4, 1, 5, 9, 1, 1]

  # Basic Character Set (also adds '#' from the Extended Character Set)
  BCS = <<~'end'.gsub(/\s+/, '').concat(' ').split('')
    A B C D E F G H I J K L M N O P Q R S T U V W X Y Z
    0 1 2 3 4 5 6 7 8 9
    ! " # & ' ( ) * + , - . / : ; = ?
  end

  # delimiter  pos chr
  # ---------- --- ---
  # field        4 (*)
  # composite  105 (:)
  # repetition  83 (^)
  # segment    106 (~)

  def initialize(obj=nil, *etc)
    if obj.is_a?(String) && !etc.empty?
      obj = etc.dup.unshift(obj)
    elsif obj
      obj = obj.dup # does this need to be a deep clone?
    end
    case obj
      when nil
      when String then @str = obj unless obj.empty?
      when Array
      when Hash
      when IO     then @str = obj = obj.read
      when X12    then @str = obj.to_s
      else raise "unable to handle #{arg.class} objects"
    end
    @str ||= isa_widths!("ISA*00**00**ZZ**ZZ****^*00501**0*P*:~")
    @str =~ /\AISA(.).{78}(.).{21}(.)(.)/ or raise "malformed X12"
    @fld, @com, @rep, @seg = $~.captures.values_at(0, 2, 1, 3)
    @rep = "^" if @rep == "U"
    @sep = [@fld, @com, @rep, @seg]
    @bad = regex_chars!(BCS + @sep) # invalid in txn bytes #!# BARELY USED NOW???
    @chr = regex_chars!(BCS - @sep) # invalid in user data #!# NOT USED RIGHT NOW
    case obj
      when String, nil then to_a; @str = nil
      when Array       then set(obj.shift, obj.shift) until obj.empty?
      when Hash        then obj.each {|k, v| set(k, v) unless v.nil?}
    end
    to_s unless @str
  end

  def self.load(file)
    str = File.open(file, "r:bom|utf-8", &:read) rescue "unreadable file"
    new(str)
  end

  def self.[](*args)
    new(*args)
  end

  def regex_chars(ary, invert=false)
    chrs = ary.sort.uniq # ordered list of given characters
              .chunk_while {|prev, curr| curr.ord == prev.ord + 1 } # find runs
              .map do |chunk| # build character ranges
                (chunk.length > 1 ? [chunk.first, chunk.last] : [chunk.first])
                .map {|chr| "^[]-\\".include?(chr) ? Regexp.escape(chr) : chr }
                .join("-")
              end
              .join # join ranges together
              .prepend("[#{'^' if invert}") # invert or not
              .concat("]") # reject these character ranges
    /#{chrs}/ # return as a regex
  end

  def regex_chars!(ary, invert=true)
    regex_chars(ary, invert)
  end

  def to_a
    @ary ||= @str.strip.split(/[#{Regexp.escape(@seg)}\r\n]+/).map {|str| str.split(@fld, -1)}
  end

  def to_a!
    to_a
    @str = nil
    @ary
  end

  def to_s
    @str ||= @ary.inject("") {|str, seg| str << seg.join(@fld) << "#{@seg}\n"}.chomp
  end

  def to_s!
    to_s
    @ary = nil
    @str
  end

  def raw
    to_s.delete("\n").upcase #!# NOTE: Fix these... should all sets be checked?
  end

  def show!
    to_a.each {|r| puts ansi(r.inspect, "fff", "369") }
    self
  end

  def show(*opts)
    full = opts.include?(:full) # show body at top
    deep = opts.include?(:deep) # dive into repeats
    down = opts.include?(:down) # show segments in lowercase
    list = opts.include?(:list) # give back a list or print it
    hide = opts.include?(:hide) # hide output
    only = opts.include?(:only) # only show first of each segment type
    left = opts.grep(Integer).first || 15 # left justify size

    out = full ? [to_s] : []

    unless hide
      out << "" if full
      nums = Hash.new(0)
      segs = to_a
      segs.each_with_index do |flds, i|
        seg = down ? flds.first.downcase : flds.first.upcase
        num = (nums[seg] += 1)
        flds.each_with_index do |fld, j|
          next if !fld || fld.empty? || j == 0
          if deep
            reps = fld.split(@rep)
            if reps.size > 1
              reps.each_with_index do |set, k|
                tag = "#{seg}%s-#{j}(#{k + 1})" % [num > 1 && !only ? "(#{num})" : ""]
                out << (tag.ljust(left) + set)
              end
              next
            end
          end
          tag = "#{seg}%s-#{j}" % [num > 1 && !only ? "(#{num})" : ""]
          out << (tag.ljust(left) + wrap(fld, "fff", "369"))
        end
      end
    end

    list ? out : (puts out)
  end

  def normalize(obj)
    if Array === obj
      obj.each_with_index do |elt, i|
        str = (String === elt) ? elt : (obj[i] = elt.to_s)
        str.upcase!
        str.gsub!(@bad, ' ')
      end
    else
      str = (String === obj) ? obj : obj.to_s
      str.upcase!
      str.gsub!(@bad, ' ')
      str
    end
  end

  def isa_widths(row)
    row.each_with_index do |was, i|
      len = LEN[i]
      was.replace(was.ljust(len)[...len]) if was && len && was.size != len
    end
  end

  def isa_widths!(str)
    sep = str[3] or return str
    isa_widths(str.split(sep)).join(sep)
  end

  def data(*args)
    len = args.size; return update(*args) if len > 2
    pos = args[0] or return @str
    val = args[1]

    # Syntax: seg(num)-fld(rep).com
    pos =~ /^(..[^-.(]?)?(?:\((\d*|[+!?*]?)\))?[-.]?(\d+)?(?:\((\d*|[+!?*]?)\))?[-.]?(\d+)?$/
    seg = $1 or return ""; want = /^#{seg}[^#{Regexp.escape(@seg)}\r\n]*/i
    num = $2 && $2.to_i; new_num = $2 == "+"; ask_num = $2 == "?"; all_num = $2 == "*"
    rep = $4 && $4.to_i; new_rep = $4 == "+"; ask_rep = $4 == "?"; all_rep = $4 == "*"
    fld = $3 && $3.to_i; len > 1 && fld == 0 and raise "zero index on field"
    com = $5 && $5.to_i; len > 1 && com == 0 and raise "zero index on component"

    # NOTE: When doing a get, a missing num or rep means get the first
    # NOTE: When doing a set, a missing num or rep means set the last
    # NOTE: ask_num and ask_rep are mutually exclusive, how should we handle?
    # NOTE: all_num and all_rep are mutually exclusive, how should we handle?
    # NOTE: ask_* is only for get
    # NOTE: all_* is only for get and set [is this correct?]

    if len == 1 # get
      to_s unless @str
      return @str.scan(want).size if ask_num && !ask_rep
      return @str.scan(want).inject([]) do |ary, out|
        out = loop do
          out = out.split(@fld)[fld    ] or break if fld
          break out.split(@rep).size if ask_rep
          out = out.split(@rep)[rep - 1] or break if rep || (com && (rep ||= 1))
          out = out.split(@com)[com - 1] or break if com
          break out
        end
        ary << out if out
        ary
      end if all_num
      out = @str.scan(want)[num - 1] or return "" if num ||= 1
      out = out.split(@fld)[fld    ] or return "" if fld
      return out.split(@rep).size if ask_rep
      out = out.split(@rep)[rep - 1] or return "" if rep || (com && (rep ||= 1))
      out = out.split(@com)[com - 1] or return "" if com
      out
    else # set
      to_a unless @ary
      @str &&= nil
      our = @ary.select {|now| now[0] =~ want}
      unless all_num
        num ||= 0 # default to last
        row = our[num - 1] or pad = num - our.size
        pad = 1 if (num == 0 && our.size == 0 || new_num)
        pad and pad.times { @ary.push(row = [seg.upcase]) }
        val = our.size + pad if new_num && val == :num # auto-number
        our = [row]
      end

      # prepare the source and decide how to update
      val ||= ""
      how = case
      when        !rep && !com # replace fields
        val = val.join(@fld) if Array === val
        val = val.to_s.split(@fld, -1)
        :fld
      when fld &&  rep && !com # replace repeats
        val = val.join(@rep) if Array === val
        val.include?(@fld) and raise "invalid separator for repeats"
        val = val.to_s.split(@rep, -1)
        :rep
      when fld &&          com # replace components
        val = val.join(@com) if Array === val
        val.include?(@fld) and raise "invalid separator for repeats"
        val.include?(@rep) and raise "invalid separator for repeats"
        val = val.to_s.split(@com, -1)
        :com
      end or raise "invalid fld/rep/com: #{[fld, rep, com].inspect}"
      val = [""] if val.empty?

      #!# TODO: val.dup to prevent sharing issues???

      # replace the target
      our.each do |row|
        case how
        when :fld
          if fld
            pad = fld - row.size
            pad.times { row.push("") } if pad > 0
            row[fld, val.size] = val
          else
            row[1..-1] = val
          end
        when :rep
          if (was = row[fld] ||= "").empty?
            was << @rep * (rep - 1) if rep > 1
            was << val.join(@rep)
          else
            ufr = was.split(@rep, -1) # unpacked repeats
            pad = rep - ufr.size
            pad = 1 if new_rep || rep == 0 && ufr.empty?
            pad.times { ufr.push("") } if pad > 0
            ufr[rep - 1, val.size] = val
            was.replace(ufr.join(@rep)) # repacked repeats
          end
        when :com
          rep ||= 0 # default to last

          if (one = row[fld] ||= "").empty?
            one << @rep * (rep - 1) if rep > 1
            one << @com * (com - 1) if com > 1
            one << val.join(@com)
          else
            ufr = one.split(@rep, -1) # unpacked repeats
            pad = rep - ufr.size
            pad = 1 if new_rep || rep == 0 && ufr.empty?
            pad.times { ufr.push("") } if pad > 0

            if (two = ufr[rep - 1] ||= "").empty?
              two << @com * (com - 1) if com > 1
              two << val.join(@com)
            else
              ucr = two.split(@com, -1) # unpacked components
              pad = com - ucr.size
              pad.times { ucr.push("") } if pad > 0
              ucr[com - 1, val.size] = val
              two.replace(ucr.join(@com)) # repacked components
            end
            one.replace(ufr.join(@rep)) # repacked repeats
          end
        end
      end

      # enforce ISA field widths
      isa_widths(row) if seg =~ /isa/i

      nil
    end
  end

  alias_method :get, :data
  alias_method :set, :data
  alias_method :[], :data
  alias_method :[]=, :data

  def update(*etc)
    etc = etc.first if etc.size == 1
    case etc
    when nil
    when Array then etc.each_slice(2) {|pos, val| data(pos, val) if val }
    when Hash  then etc.each          {|pos, val| data(pos, val) if val }
    else raise "unable to update X12 objects with #{etc.class} types"
    end
    self
  end
end

if __FILE__ == $0

  require "optparse"

  trap("INT" ) { abort "\n" }
  trap("PIPE") { abort "\n" } rescue nil

  opts = { }

  OptionParser.new.instance_eval do
    @banner  = "usage: #{program_name} [options] <file> <file> ..."

    on "-a", "--after <date>"  , "After (date as 'YYYYMMDD' or time as 'YYYYMMDD HHMMSS')"
    on "-c", "--count"         , "Count messages at the end"
    on "-d", "--dive"          , "Dive into directories recursively"
    on "-h", "--help"          , "Show help and command usage" do Kernel.abort to_s; end
    on "-i", "--ignore"        , "Ignore malformed X12 files"
    on "-l", "--lower"         , "Show segment names in lowercase"
    on "-m", "--message"       , "Show message body"
    on "-p", "--path"          , "Show path for each message"
    on "-s", "--spacer"        , "Show an empty line between messages"

    Kernel.abort to_s if ARGV.empty?
    self
  end.parse!(into: opts) rescue abort($!.message)

  opts.transform_keys!(&:to_s) # stringify keys

  require "time" if opts["after"]

  time = Time.parse(opts["after"]) if opts["after"]
  dive = opts["dive"]

  args = []
  args << :down if  opts["lower"]
  args << :full if  opts["message"] || opts.empty?

  msgs = 0

  list = []
  ARGV.push(".") if dive && ARGV.empty?
  ARGV.each do |path|
    if File.directory?(path)
      ours = []
      if dive
        Find.find(path) do |item|
          if File.file?(item)
            if time
              ours << item if File.mtime(item) > time
            else
              ours << item
            end
          end
        end
      else
        Dir[File.join(path, "*")].each do |item|
          if File.file?(item)
            if time
              ours << item if File.mtime(item) > time
            else
              ours << item
            end
          end
        end
      end
      list.concat(ours.sort!)
    elsif File.file?(path)
      if time
        list << path if File.mtime(path) > time
      else
        list << path
      end
    else
      warn "WARNING: unknown item in list: #{path.inspect}"
      next
    end
  end

  list.each do |file|
    puts if opts["spacer"] && msgs > 0
    if opts["path"]
      puts "\n==[ #{file} ]==\n\n"
    end

    begin
      str = File.open(file, "r:bom|utf-8", &:read) rescue abort("ERROR: unable to read file: \"#{file}\"")
      begin
        x12 = X12.new(str)
      rescue
        abort "ERROR: malformed X12 file: \"#{file}\" (#{$!})" unless opts["ignore"]
        next
      end
      x12.show(*args)
      msgs += 1
    rescue => e
      warn "WARNING: #{e.message}"
    end
  end

  if opts["count"] && msgs > 0
    puts "\nTotal messages: #{msgs}"
  end
end
