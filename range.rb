#!/usr/bin/env ruby

require_relative "../simpleopts.rb"

SOpt = SimpleOpts::Opt
so = SimpleOpts.get_args(["<rangexp...>",
                          {offset: 0, number: false, format: nil, header: nil,
                           grep: SOpt.new(default: nil, type: Regexp),
                           grep_after_context: SOpt.new(short: ?A, default: nil, type: Integer),
                           grep_before_context: SOpt.new(short: ?B, default: nil, type: Integer),
                           grep_context: SOpt.new(short: ?C, default: nil, type: Integer),
                           final_newline: true, concat_args: false, delimit_hunks: false}],
                          leftover_opts_key: :rangexp_candidates)
conv = proc { |n| Integer(n) - so.offset }

# Those args which were not recognized as options shall
# be now attempted to parse as range expressions.
# Along this, $* will be recreated to collect those args
# which fail this turn of parsing.
make_neighborrx = proc { |opt=""| /(?:(?<dir1>[<>]|<>)(?<step1>-?\d+))#{opt}(?:(?<dir2>[<>])(?<step2>-?\d+))?/ }
get_neighborhood = proc do |match|
  steph = {?<=> 0, ?>=> 0}
  [%i[dir1 step1], %i[dir2 step2]].each { |d,s|
    d,s = [d,s].map { |k| match[k] }
    s or next
    s = Integer(s)
    steph.each_key { |q|
     d.include? q and steph[q] = s
    }
  }
  [-steph[?<], steph[?>]].sort
end
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
      [0, conv[$2], !!$1]
    when ".."
      [0, nil]
    when /\A(?<center>-?\d+)#{make_neighborrx[]}\Z/
      c = conv[$~[:center]]
      ends = get_neighborhood[$~].send(:map, &if c >= 0
        proc { |v| [c + v, 0].max }
      else
        proc { |v| [c + v, -1].min }
      end)
      ends + [false]
    else
      $* << a
      break
    end
  }
}.flatten.compact

# Another scrub of arguments, now for regexen. Regexp syntax is Ruby-like.
# Logical combinator applied on multiple regexen is disjunction,
# (as well as with rangexps), so far that's like just '|' regexp
# operator; however, this syntax recognizes neighbour spec like for
# rangexps, like
#
#   %r/hello/<>3
#
# for a context of 3 lines, so this can be specified individually.
# Regexp flags (mainly 'i' would be useful) are also individual.
regexen = []
# Include value of -g first.
if so.grep
  regexen << {rx: so.grep, down: -(so.grep_before_context || so.grep_context || 0),
              up: so.grep_after_context || so.grep_context || 0}
end
argv_remaining = $*.dup
$*.clear
argv_remaining.each { |a|
  rxspec = if a =~ /\A%r([^\\])/
    delim_raw = $1
    end_delim_raw = [%w[< >], %w[( )], %w[{ }], %w[[ ]]].to_h[delim_raw] || delim_raw
    delim,end_delim = [delim_raw, end_delim_raw].map { |s| Regexp.escape s }
    if match = a.match(/\A%r#{delim}(?<rx>(?:[^#{end_delim}\\]|\\.)*)#{end_delim}(?<rxopts>[mix]*)#{make_neighborrx[??]}\Z/)
      {rx: Regexp.new(match[:rx].gsub(/\\#{delim}/, delim),
                      {?i=> Regexp::IGNORECASE, ?m=> Regexp::MULTILINE, ?x=> Regexp::EXTENDED}.select {|o,v|
                        match[:rxopts].include? o
                      }.values.inject(:|))
      }.merge(%i[down up].zip(get_neighborhood[match]).to_h)
    end
  end
  rxspec ? regexen << rxspec : $* << a
}

# $* holds now input files and truly invalid options.
# Fire up the option parser once more. Now if it finds anything
# that looks like an option we can let it freely pour its rage
# over it.
SimpleOpts.new.parse $*
# If we got so far, $* has our input files.

BASE_PARAMS   = {NL: "\n", TAB: "\t"}
HEADER_PARAMS = {path:"", file:"", fno:0, fno0:0, fno1:0, fidx:0, fidx0:0, fidx1:0}
FORMAT_PARAMS = {line: "", match:"", matches:[]}.merge(HEADER_PARAMS).merge(
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
pos_ranges.sort_by! { |r|
  # first entry enforces unlimited ranges going to the end, second entry gets limited
  # ranges sorted by their end value
  [r.end ? 0 : 1, r.end || 0]
}
bottom = neg_ranges.map { |r| %i[begin end].map { |m| r.send m } }.flatten.compact.min
pure_neg_ranges,mixed_ranges = neg_ranges.partition { |r| [r.begin||0, r.end||-1].all? { |v| v < 0 }}
# Those ranges which begin positive (non-negative, to be precise) and end negative are
# equivalent with the upper-open-ended positive range resulting by omitting their ends
# *provided* we are *out of* the window. Collect these transformed ranges so that we
# can match against them in such context.
# NOTE Ruby >= 2.6 semantics (infinite ranges) is used.
pseudo_pos_ranges = mixed_ranges.select { |r| (r.begin||0) >= 0 }.map { |r| (r.begin||0).. }
winsiz = ([bottom] + regexen.map { |rx| rx[:down] }).compact.map(&:abs).max || 0

Signal.trap("SIGPIPE", "SYSTEM_DEFAULT")

writer = so.final_newline ? :puts : :print

global_idx,global_lineno,fidx = 0,0,0
(so.concat_args ? [$<] : ($*.empty? ? [?-] : $*)).each_with_index do |fn, fno|
  case fn
  when $<
    proc { |&cbk| cbk[fno, '<cat>', $<] }
  when ?-
    proc { |&cbk| cbk[fno, '<stdin>', STDIN] }
  else
    proc { |&cbk| open(fn) { |fh| cbk[fno, fn, fh] } }
  end.call do |fno, fn, fh|
    formath = {}
    idx = 0
    lineno = 0
    matches = {}
    last_lno = nil

    format_line = proc do |ln, shift|
      if idx.zero?
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
            fno + so.offset
          when :fno0
            fno
          when :fno1
            fno + 1
          when :fidx
            fidx + so.offset
          when :fidx0
            fidx
          when :fidx1
            fidx + 1
          else
            raise "bad header key #{k.inspect}"
          end
        }
        so.header and puts so.header % formath
        fidx += 1
      end

      lno = lineno - shift
      current_fmt_only_keys.each { |k|
        formath[k] = case k
        when :lno
          lno + so.offset
        when :lno0
          lno
        when :lno1
          lno + 1
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
          (matches[lineno - shift]||[]).first
        when :matches
          (matches[lineno - shift]||[]).map(&:dump).join ?,
        else
          raise "bad format key #{k.inspect}"
        end
      }
      if so.delimit_hunks and last_lno and last_lno < lno - 1
        puts "--"
      end
      STDOUT.send writer, format % formath
      global_idx +=1
      idx += 1
      last_lno = lno
    end

    pos_ranges_current = pos_ranges.dup
    window = []
    fh.each_with_index { |line,_lineno|
      lineno = _lineno
      window << line
      regexen.each { |rx|
        if rx[:rx] =~ line
          (matches[lineno]||=[]) << $&
          # inject ad hoc entry for match neighborhood
          pos_ranges_current.insert 0, [lineno + rx[:down], 0].max..lineno + rx[:up]
        end
      }
      if window.size > winsiz
        outline = window.shift
        # calculating line number of currently processed
        # line from line number of latest read line
        lno = lineno - winsiz
        if
          pos_ranges_current.delete_if.with_object(false) { |r|
            r.include? lno and break true
            # we passed over r, it can be dropped
            lno >= r.begin
          } or pseudo_pos_ranges.any? { |r| r.include? lno }
        then
          format_line[outline, winsiz]
        end
      end
      [pos_ranges_current, neg_ranges, regexen].all? { |ra| ra.empty? } and break
      # drop match record for a line known to be out of the window
      matches.size > winsiz and matches.delete(matches.each_key.first)
      global_lineno += 1
    }

    # exhausted file, now negative indices can be
    # dereferenced in window, so decide about
    # lines in window, considering all ranges.
    window.each_with_index do |l,i|
      neglno = i - window.size
      shift = window.size - i - 1
      lno = lineno - shift
      if
        pos_ranges_current.any? { |r| r.include? lno } or
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
      then
        format_line[l, shift]
      end
    end

  end
end
