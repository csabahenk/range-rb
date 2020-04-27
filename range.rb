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

neg_ranges,pos_ranges = ranges.partition { |r| %i[begin end].any? {|m| (r.send(m)||0) < 0 }}
bottom = neg_ranges.map { |r| %i[begin end].map { |m| r.send m } }.flatten.compact.min
pure_neg_ranges,mixed_ranges = neg_ranges.partition { |r| [r.begin||0, r.end||-1].all? { |v| v < 0 }}
# Those ranges which begin positive (non-negative, to be precise) and end negative are
# equivalent with the upper-open-ended positive range resulting by omitting their ends
# *provided* we are *out of* the window. Collect these transformed ranges so that we
# can match against them in such context.
# NOTE Ruby >= 2.6 semantics (infinite ranges) is used.
pseudo_pos_ranges = pos_ranges + mixed_ranges.select { |r| (r.begin||0) >= 0 }.map { |r| (r.begin||0).. }
winsiz = (bottom||0).abs

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

    idx = 0
    lineno = 0
    decide_line = proc do |ln, shift, &rangeval|
      match = nil
      if rangeval[] or (
        if so.grep and ln =~ so.grep
          match = $&
          true
        else
          false
        end
      )
        current_fmt_only_keys.each { |k|
          formath[k] = case k
          when :lno
            lineno + so.offset - shift
          when :lno0
            lineno - shift
          when :lno1
            lineno + 1 - shift
          when :LNO
            global_lineno + so.offset - shift
          when :LNO0
            global_lineno - shift
          when :LNO1
            global_lineno + 1 - shift
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
            ln
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
    end

    window = []
    fh.each_with_index { |line,_lineno|
      lineno = _lineno
      window << line
      if window.size > winsiz
        outline = window.shift
        decide_line.call(outline, winsiz) {
          pseudo_pos_ranges.any? { |r| r.include?(lineno - winsiz) }
        }
      end
      global_lineno += 1
    }

    # exhausted file, now negative indices can be
    # dereferenced in window, so decide about
    # lines in window, considering all ranges.
    window.each_with_index do |l,i|
      neglno = i - window.size
      shift = window.size - i - 1
      lno = lineno - shift
      decide_line.call(l, shift) do
        pos_ranges.any? { |r| r.include? lno } or
        pure_neg_ranges.any? { |r| r.include? neglno } or
        # for mixed ranges we have to manually check
        # relations as different index is matched against
        # upper and lower boundary
        mixed_ranges.any? { |r|
          [[r.begin, :>=],
           [r.end, r.exclude_end? ? :< : :<=]].all? { |e,rel|
            if e
              (e < 0 ? neglno : lno).send rel, e
            else
              true
            end
          }
        }
      end
    end

  end
end
