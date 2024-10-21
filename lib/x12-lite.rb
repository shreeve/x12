#!/usr/bin/env ruby

# ==============================================================================
# x12-lite.rb: X12 library for Ruby
#
# Author: Steve Shreeve <steve.shreeve@gmail.com>
#   Date: October 16, 2024
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
  VERSION="0.4.0"

  include Enumerable

  # ISA field widths
  LEN = [3, 2, 10, 2, 10, 2, 15, 2, 15, 6, 4, 1, 5, 9, 1, 1]

  # Basic Character Set (also adds '#' from the Extended Character Set)
  BCS = <<~'end'.gsub(/\s+/, '').concat(' ').split('')
    A B C D E F G H I J K L M N O P Q R S T U V W X Y Z
    0 1 2 3 4 5 6 7 8 9
    ! " # & ' ( ) * + , - . / : ; = ?
  end

  REGEX = /^
    (..[^-.(]?)            # seg: eb
    (?:\((\d*|[+!?*]?)\))? # num: eb(3)
    [-.]?(\d+)?            # fld: eb(3)-4
    (?:\((\d*|[+!?*]?)\))? # rep: eb(3)-4(5)
    [-.]?(\d+)?$           # com: eb(3)-4(5).6
  /x

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
    list = opts.include?(:list) # puts output or return a list
    hide = opts.include?(:hide) # hide output
    only = opts.include?(:only) # only show first of each segment type
    ansi = opts.include?(:ansi) # highlight data using ansi color codes
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
          out << (tag.ljust(left) + (ansi ? ansi(fld, "fff", "369") : fld))
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
    pos =~ REGEX or raise "bad selector '#{pos}'"
    seg = $1; want = /^#{seg}[^#{Regexp.escape(@seg)}\r\n]*/i
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

  def each(seg=nil)
    to_a.each do |row|
      next if seg && !(seg === row.first)
      yield row
    end
  end

  # means this each may change @ary, so clear @str in case
  def each!(...)
    out = each(...)
    @str &&= nil
    out
  end

  def grep(seg)
    reduce([]) do |ary, row|
      ary.push(block_given? ? yield(row) : row) if seg === row.first
      ary
    end
  end

  def find(*ask)
    return if ask.empty?

    str = to_s
    say = []

    ask.each do |pos|
      say.push(nil) && next if pos.nil?
      pos =~ REGEX or raise "bad selector '#{pos}'"
      seg = $1; want = /^#{seg}[^#{Regexp.escape(@seg)}\r\n]*/i
      num = $2 && $2.to_i; new_num = $2 == "+"; ask_num = $2 == "?"; all_num = $2 == "*"
      rep = $4 && $4.to_i; new_rep = $4 == "+"; ask_rep = $4 == "?"; all_rep = $4 == "*"
      fld = $3 && $3.to_i; len > 1 && fld == 0 and raise "zero index on field"
      com = $5 && $5.to_i; len > 1 && com == 0 and raise "zero index on component"

      if all_num
        raise "multi query allows only one selector" if ask.size > 1
        return str.scan(want).inject([]) do |ary, out|
          out = loop do
            out = out.split(@fld)[fld  ] or break if fld
            break out.split(@rep).size if ask_rep
            out = out.split(@rep)[rep - 1] or break if rep || (com && (rep ||= 1))
            out = out.split(@com)[com - 1] or break if com
            break out
          end
          ary << out if out
          ary
        end
      end

      say << loop do
        out = ""
        break str.scan( want).size if ask_num && !ask_rep
        out = str.scan( want)[num - 1] or break "" if num ||= 1
        out = out.split(@fld)[fld    ] or break "" if fld
        break out.split(@rep).size if ask_rep
        out = out.split(@rep)[rep - 1] or break "" if rep || (com && (rep ||= 1))
        out = out.split(@com)[com - 1] or break "" if com
        break out
      end
    end

    say.size > 1 ? say : say.first
  end

#   def now(fmt="%Y%m%d%H%M%S")
#     Time.now.strftime(fmt)
#   end
#
#   def guid
#     ("%9.6f" % Time.now.to_f).to_s.sub(".", "")
#   end
#
#   def each_pair
#     nums = Hash.new(0)
#     segs = to_a
#     segs.each_with_index do |flds, i|
#       seg = flds.first.downcase
#       num = nums[seg] += 1
#       msh = seg == "msh"
#       adj = msh ? 1 : 0
#       flds.each_with_index do |fld, j|
#         next if !fld || fld.empty? || j == 0
#         if !msh and (reps = fld.split(@rep)).size > 1
#           reps.each_with_index do |set, k|
#             tag = "#{seg}%s-#{j + adj}(#{k + 1})" % [num > 1 ? "(#{num})" : ""]
#             yield(tag, set)
#           end
#           next
#         else
#           tag = "#{seg}%s-#{j + adj}" % [num > 1 ? "(#{num})" : ""]
#           yield(tag, fld)
#         end
#       end
#     end
#   end
#
#   def to_pairs
#     ary = []
#     saw = Hash.new(0)
#
#     to_a.each_with_index do |row, i|
#       seg = row.first.downcase
#       num = saw[seg] += 1
#       msh = seg.upcase == "MSH"
#       adj = msh ? 1 : 0
#       row.each_with_index do |val, j|
#         next if val.blank? || j == 0
#         tag = "#{seg}%s-#{j + adj}" % [num > 1 ? "(#{num})" : ""]
#         if !msh && val.include?(@rep)
#           val.split(@rep).each_with_index do |val, k|
#             ary << [tag + "(#{k + 1})", val] unless val.blank?
#           end
#         else
#           ary << [tag, val]
#         end
#       end
#     end
#
#     ary
#   end
#
#   def pluck(row, *ask)
#     return if ask.empty?
#
#     str = (String === row) ? row : row.join(@fld)
#     say = []
#
#     msh = str =~ /^MSH\b/i # is this an MSH segment?
#
#     ask.each do |pos|
#       say.push(nil) && next if pos.nil?
#       pos = pos.to_s unless pos.is_a?(String)
#       pos =~ /^([A-Z]..)?(?:\((\d*)\))?[-.]?(\d+)?(?:\((\d*)\))?[-.]?(\d+)?[-.]?(\d+)?$/i
#       seg = $1 && $1.upcase; raise "asked for a segment of #{seg}, but given #{str}" if (seg && seg != str[0, seg.size].upcase)
#       num = $2 && $2.to_i; # this will be ignored
#       fld = $3 && $3.to_i
#       rep = $4 && $4.to_i
#       com = $5 && $5.to_i
#       sub = $6 && $6.to_i
#
#       fld -= 1 if msh && fld # MSH fields are offset by one
#
#       out = str.dup
#       out = out.split(@fld)[fld    ] if out && fld
#       out = out.split(@rep)[rep - 1] if out && rep || (com && (rep ||= 1)) # default to first
#       out = out.split(@com)[com - 1] if out && com
#       out = out.split(@sub)[sub - 1] if out && sub
#       say << (out || "")
#     end
#
#     say.size > 1 ? say : say.first
#   end
#
#   def populate(hash, want)
#     list = find(*want.values)
#     keys = want.keys
#     keys.size == list.size or raise "mismatch (#{keys.size} keys, but #{list.size} values)"
#     keys.each {|item| hash[item] = list.shift }
#     hash
#   end
#
#   def glean(want, *rest)
#     row  = rest.pop           if Array  === rest.last || Hash    === rest.last
#     want = rest.unshift(want) if String === want      || Numeric === want
#     want, row = row, want     if Array  === want      && Hash    === row
#
#     case row
#     when Array
#       case want
#       when String, Array
#         vals = pluck(row, *want)
#       when Hash
#         keys = want.keys
#         vals = pluck(row, *want.values)
#         hash = keys.zip(vals).to_h
#       else raise "unable to glean X12 segments with #{want.class} types"
#       end
#     when nil
#       case want
#       when String, Array
#         vals = find(*want)
#       when Hash
#         keys = want.keys
#         vals = Array(find(*want.values)) # ensure we get an array
#         hash = keys.zip(vals).to_h
#       else raise "unable to glean X12 segments with #{want.class} types"
#       end
#     else raise "unable to glean X12 objects from #{row.class} types"
#     end
#   end
#
#   # NOTE: this could be merged with grep()
#   def slice(who, *ask)
#     return if ask.empty?
#
#     all = ask.map do |pos|
#       pos.to_s =~ /^([A-Z]..)?(?:\((\d*)\))?[-.]?(\d+)?(?:\((\d*)\))?[-.]?(\d+)?[-.]?(\d+)?$/i
#       seg = $1 && $1.upcase
#       num = $2 && $2.to_i; # this will be ignored
#       fld = $3 && $3.to_i or raise "invalid field specifier in '#{pos}'"
#       rep = $4 && $4.to_i
#       com = $5 && $5.to_i
#       sub = $6 && $6.to_i
#       [seg, num, fld, rep, com, sub]
#     end
#
#     grep(who).map do |row|
#       str ||= row[0]
#       msh ||= str == "msh" # is this an MSH segment?
#       all.inject([]) do |ary, (seg, num, fld, rep, com, sub)|
#         raise "scanning #{str} segments, but asked for #{seg}" if (seg && seg != str)
#         out = row[msh ? fld - 1 : fld].dup
#         out = out.split(@rep)[rep - 1] if out && rep || (com && (rep ||= 1)) # default to first
#         out = out.split(@com)[com - 1] if out && com
#         out = out.split(@sub)[sub - 1] if out && sub
#         ary << (out || "")
#       end
#     end
#   end
end

__END__

x12 = X12.new

# fields
x12["seg"] =  nil
x12["seg"] =  ""
x12["seg"] =  "a"
x12["seg"] =  "a*b"
x12["seg"] =  "**c*d"
x12["seg"] =  "**c:e^f*d"

x12["seg"] = [nil                 ]
x12["seg"] = [""                  ]
x12["seg"] = ["","","",""         ]
x12["seg"] = ["a"                 ]
x12["seg"] = ["a", "b"            ]
x12["seg"] = ["", "", "c", "d"    ]
x12["seg"] = ["", "", "c:e^f", "d"]
x12["seg"] = ["**c:e^f", "d"]

# repeats
x12["seg-2(3)"] =  "^^c:e^^"
x12["seg-2(3)"] =  ""
x12["seg-2(3)"] =  nil
x12["seg-2(5)"] =  nil
x12["seg-2(3)"] =  "a"
x12["seg-2(3)"] =  "a^b"
x12["seg-2(3)"] =  "^^c^d"

x12["seg-2(3)"] = [nil                 ]
x12["seg-2(3)"] = [""                  ]
x12["seg-2(3)"] = ["a"                 ]
x12["seg-2(3)"] = ["a", "b"            ]
x12["seg-2(3)"] = ["", "", "c", "d"    ]
x12["seg-2(3)"] = ["", "", "c:e^f", "d"]
x12["seg-2(3)"] = ["c:e^f", "d"]

# components
x12["seg-2(3).1"] =  "c:e"
x12["seg-2(3).4"] =  ""
x12["seg-2(3).1"] =  nil
x12["seg-2(5).4"] =  nil
x12["seg-2(3).1"] =  "a"
x12["seg-2(5).2"] =  "a:b"
x12["seg-2(5).4"] =  "::c:d"

x12["seg-2.1"] = [nil                 ]
x12["seg-2.4"] = [""                  ]
x12["seg-2.1"] = ["a"                 ]
x12["seg-2.4"] = ["a", "b"            ]
x12["seg-2.1"] = ["", "", "c", "d"    ]
x12["seg-2.2"] = ["", "", "c:e:f", "d"]
x12["seg-2.4"] = ["c:e:f", "d"        ]

# p x12.to_a

__END__

position fld rep com
======== === === ===

# fields
seg       nil nil nil # replace fields, complete
seg-1       1 nil nil # replace fields, starting from field 1
seg-2       2 nil nil # replace fields, starting from field 2

# repeats
seg-1(1)    1   1 nil # replace repeats for field 1, starting from repeat 1
seg-1(3)    1   3 nil # replace repeats for field 1, starting from repeat 3
seg-2(1)    2   1 nil # replace repeats for field 2, starting from repeat 1
seg-2(3)    2   3 nil # replace repeats for field 2, starting from repeat 3

# components
seg-1.1     1 nil   1 # replace components for field 1, starting from component 1
seg-1.4     1 nil   4 # replace components for field 1, starting from component 4
seg-2.1     2 nil   1 # replace components for field 2, starting from component 1
seg-2.4     2 nil   4 # replace components for field 2, starting from component 4
seg-1(1).1  1   1   1 # replace components for field 1, repeat 1, starting from component 1
seg-1(1).4  1   1   4 # replace components for field 1, repeat 1, starting from component 4
seg-2(1).1  2   1   1 # replace components for field 2, repeat 1, starting from component 1
seg-2(1).4  2   1   4 # replace components for field 2, repeat 1, starting from component 4
seg-1(3).1  1   3   1 # replace components for field 1, repeat 3, starting from component 1
seg-1(3).4  1   3   4 # replace components for field 1, repeat 3, starting from component 4
seg-2(3).1  2   3   1 # replace components for field 2, repeat 3, starting from component 1
seg-2(3).4  2   3   4 # replace components for field 2, repeat 3, starting from component 4

x12 = X12.new [
  "gs-2", "...",
  "gs-8", "...",
  "foo", "wow",
]

x12 = X12.new <<~""
  ISA*00*          *00*          *ZZ*HT009382-001   *ZZ*HT000004-001   *240626*0906*^*00501*000923871*0*P*:~
  GS*HS*HT009382-001*HT000004-001*20240626*0906*923871*X*005010X279A1~

x12.show(:down)

__END__

class DefaultArray < Array
  def initialize(default_value = nil)
    @default_value = default_value
    super()
  end

  def [](index)
    self[index] = @default_value if index >= size
    super
  end
end

# Usage
arr = DefaultArray.new(0)  # Create a new array with default value 0

puts arr[2]  # => 0 (accessing non-existent element sets it to default 0)
puts arr.inspect  # => [0, 0, 0] (array is now filled with default values)
