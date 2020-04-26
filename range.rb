#!/usr/bin/env ruby

require_relative "../simpleopts.rb"

SOpt = SimpleOpts::Opt
so = SimpleOpts.get_args(["<rangexp...>",
                          {offset: 0, number: false, format: nil, header: nil,
                           grep: SOpt.new(default: nil, type: Regexp),
                           final_newline: true, concat_args: false}],
                          leftover_opts_key: :rangexp_candidates)
conv = proc { |n| Integer(n) - so.offset }

# Those args which were not recognized as options shall
# be now attempted to parse as range expressions.
# Along this, $* will be recreated to collect those args
# which fail this turn of parsing.
argv_remaining = so.rangexp_candidates + $*
$*.clear
ranges = argv_remaining.map { |a|
  a.split(/\s*,\s*/).map { |b|
    Range.new *case b
    when /\A(-?\d+)\Z/
      conv[$1].then {|n| [n,n,false] }
    when /\A(-?\d+)(?:(?:\.{2}|-)|(\.{3}))(-?\d+)?\Z/
      [$1,$3].map{|s| s ? conv[s] : nil} + [!!$2]
    when /\A\.\.(\.)?(-?\d+)\Z/
      [nil, conv[$2], !!$1]
    when ".."
      [0, nil]
    when /\A(?<center>-?\d+)(?<dir1>[<>]|<>)(?<step1>-?\d+)(?:(?<dir2>[<>])(?<step2>-?\d+))?/
      c = conv[$~[:center]]
      steph = {?<=> 0, ?>=> 0}
      [%i[dir1 step1], %i[dir2 step2]].each { |d,s|
        d,s = [d,s].map { |k| $~[k] }
        s or next
        s = Integer(s)
        steph.each_key { |q|
         d.include? q and steph[q] = s
        }
      }
      ends = [c - steph[?<], c + steph[?>]].sort.send(:map, &if c >= 0
        proc { |v| [v,0].max }
      else
        proc { |v| [v,-1].min }
      end)
      ends + [false]
    else
      $* << a
      break
    end
  }
}.flatten.compact
# $* holds now input files and truly invalid options.
# Fire up the option parser once more. Now if it finds anything
# that looks like an option we can let it freely pour its rage
# over it.
SimpleOpts.new.parse $*
# If we got so far, $* has our input files.

BASE_PARAMS   = {NL: "\n", TAB: "\t"}
HEADER_PARAMS = {path:"", file:"", fno:0, fno0:0, fno1:0}
FORMAT_PARAMS = {line: "", match:""}.merge(HEADER_PARAMS).merge(
                 lno:0, lno0:0, lno1:0, LNO:0, LNO0:0, LNO1:0,
                 idx:0, idx0:0, idx1:0, IDX:0, IDX0:0, IDX1:0)

format = so.format
if not format
  format = if so.number
    "%{lno} %{line}"
  else
    "%{line}"
  end
end
[['header', so.header || "", HEADER_PARAMS],
  ['format', format, FORMAT_PARAMS]].each do |opt, fmt, prm|
  fmt % prm.merge(BASE_PARAMS)
rescue KeyError
  STDERR.puts "invalid parameters in '--#{opt} #{fmt}'",
              "valid parameters are:", prm.merge(BASE_PARAMS).keys
  exit 1
end
# find out which parameters occur in the given header
# and format templates by omitting them one by one
# from the parameters and see if this reduced mapping
# is able to render the template; if not, the omitted
# parameter is proven to occur.
current_header_keys, current_format_keys = [
  [so.header || "", HEADER_PARAMS],
  [format, FORMAT_PARAMS]
].map { |fmt, prm|
  prmb = BASE_PARAMS.merge prm
  prmb.each_key.with_object([]) { |k,aa|
    prmk = prmb.dup
    prmk.delete k
    begin
      fmt % prmk
    rescue KeyError
      aa << k
    end
  }
}
# keys that should be set upon visitng a file,
# either because used in the header, or because
# are used in line formatting but not changing
# in the scope of the file
current_hdr_fmt_keys = current_header_keys | (current_format_keys & HEADER_PARAMS.keys)
# keys that are used in line formatting and are
# chaging from line to line
current_fmt_only_keys = current_format_keys - HEADER_PARAMS.keys

has_neg = ranges.find { |r| %i[begin end].find {|m| (r.send(m)||0) < 0 }}
writer = so.final_newline ? :puts : :print

global_idx,global_lineno = 0,0
(so.concat_args ? [$<] : ($*.empty? ? [?-] : $*)).each_with_index do |fn, fidx|
  case fn
  when $<
    proc { |&cbk| cbk[fidx, '<cat>', $<] }
  when ?-
    proc { |&cbk| cbk[fidx, '<stdin>', STDIN] }
  else
    proc { |&cbk| open(fn) { |fh| cbk[fidx, fn, fh] } }
  end.call do |fidx, fn, fh|
    formath = {}
    current_hdr_fmt_keys.each { |k|
      formath[k] = case k
      when :NL
        "\n"
      when :TAB
        "\t"
      when :path
        fn
      when :file
        File.basename(fn)
      when :fno
        fidx + so.offset
      when :fno0
        fidx
      when :fno1
        fidx + 1
      else
        raise "bad header key #{k.inspect}"
      end
    }
    so.header and puts so.header % formath

    inp,ra = if has_neg
      lines = fh.readlines
      [lines, (0...lines.size).to_a.then {|a| ranges.map {|r| a[r] }}]
    else
      [fh, ranges]
    end

    idx = 0
    inp.each_with_index { |line,lineno|
      match = nil
      if ra.find { |r| r.include? lineno } or (
        if so.grep and line =~ so.grep
          match = $&
          true
        else
          false
        end
      )
        current_fmt_only_keys.each { |k|
          formath[k] = case k
          when :lno
            lineno + so.offset
          when :lno0
            lineno
          when :lno1
            lineno + 1
          when :LNO
            global_lineno + so.offset
          when :LNO0
            global_lineno
          when :LNO1
            global_lineno + 1
          when :idx
            idx + so.offset
          when :idx0
            idx
          when :idx1
            idx + 1
          when :IDX
            global_idx + so.offset
          when :IDX0
            global_idx
          when :IDX1
            global_idx + 1
          when :line
            line
          when :match
            match
          else
            raise "bad format key #{k.inspect}"
          end
        }
        begin
          STDOUT.send writer, format % formath
        rescue Errno::EPIPE
          exit 0
        end
        global_idx +=1
        idx += 1
      end
      global_lineno += 1
    }
  end
end
