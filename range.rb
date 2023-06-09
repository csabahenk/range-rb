#!/usr/bin/env ruby

require "json"
require_relative "lib/simpleopts/simpleopts"

BASE_PARAMS   = {NL: "\n", TAB: "\t", NUL: "\0",
                 BLACK: "\e[0;30;49m", RED: "\e[0;31;49m", GREEN: "\e[0;32;49m", YELLOW: "\e[0;33;49m",
                 BLUE: "\e[0;34;49m", MAGENTA: "\e[0;35;49m", CYAN: "\e[0;36;49m", WHITE: "\e[0;37;49m",
                 CLR: "\e[0m"}
HEADER_PARAMS = {path:"", file:"", dir:"", fno:0, fno0:0, fno1:0, fidx:0, fidx0:0, fidx1:0}
FORMAT_PARAMS = {line: "", len: 0, chomp: "", strip: "", rstrip: "", lstrip: "", dump: "", json: "",
                 match:"", matches:[]}.merge(HEADER_PARAMS).merge(
                 lno:0, lno0:0, lno1:0, LNO:0, LNO0:0, LNO1:0,
                 idx:0, idx0:0, idx1:0, IDX:0, IDX0:0, IDX1:0)

# The delimiters that can be used in Ruby style regexp literarls.
RXDELIMS = %w[ ! " # $ % & ' ) * + , - . / : ; = > ? @ \\ \] ^ _ ` | } ~  ( { \[  < ]
# we don't accept following as they are special to our special syntax
RXDELIM_BLACKLIST = %w[ < > - \\ ]
RXDELIMMAP = [%w[< >], %w[( )], %w[{ }], %w[[ ]]].to_h

SOpt = SimpleOpts::Opt
so = SimpleOpts.get_args(["<rangexp...>",
                          {offset: 0, number: false, format: nil, header: nil, footer: nil,
                           grep: SOpt.new(default: nil, type: Regexp),
                           grep_invert_match: SOpt.new(short: ?v, default: false),
                           grep_after_context: SOpt.new(short: ?A, default: nil, type: Integer),
                           grep_before_context: SOpt.new(short: ?B, default: nil, type: Integer),
                           grep_context: SOpt.new(short: ?C, default: nil, type: Integer),
                           force_end: %w[newline cleartty], concat_args: false, delimit_hunks: false}],
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
  regexen << {rx: so.grep, inverse: so.grep_invert_match,
              down: -(so.grep_before_context || so.grep_context || 0),
              up: so.grep_after_context || so.grep_context || 0}
end
argv_remaining = $*.dup
$*.clear
argv_remaining.each { |a|
  rxspec = if a =~ /\A%r(.)/ and (RXDELIMS - RXDELIM_BLACKLIST).include? $1
    delim_raw = $1
    end_delim_raw = RXDELIMMAP[delim_raw] || delim_raw
    delim,end_delim = [delim_raw, end_delim_raw].map { |s| Regexp.escape s }
    delim_unescape = proc { |s| s.gsub(/\\#{end_delim_raw}/, end_delim_raw) }
    if match = a.match(/\A%(?<inverse>!)?r
                          #{delim}(?<rx>(?:[^#{end_delim}\\]|\\.)*)#{end_delim}
                             (?:(?<subs>(?:[^#{end_delim}\\]|\\.)*)#{end_delim})?
                          (?<rxopts>[mix]*)
                          #{make_neighborrx[??]}\Z/x)
    then
      {rx: Regexp.new(delim_unescape[match[:rx]],
                      {?i=> Regexp::IGNORECASE, ?m=> Regexp::MULTILINE, ?x=> Regexp::EXTENDED}.select {|o,v|
                        match[:rxopts].include? o
                      }.values.inject(:|)),
       inverse: !!match[:inverse],
      }.merge(match[:subs] ? {subs: begin
                                delim_unescape[match[:subs]] % BASE_PARAMS
                              rescue KeyError
                                STDERR.puts "invalid parameters in substitution",
                                            "valid parameters are:", BASE_PARAMS.keys
                                exit 1
                              end} : {}
      ).merge(%i[down up].zip(get_neighborhood[match]).to_h)
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

format = so.format
if not format
  format = if so.number
    "%{lno} %{line}"
  else
    "%{line}"
  end
end
[['header', so.header || "", HEADER_PARAMS],
  ['format', format, FORMAT_PARAMS],
  ['footer', so.footer || "", FORMAT_PARAMS]].each do |opt, fmt, prm|
  fmt % prm.merge(BASE_PARAMS)
rescue KeyError
  STDERR.puts "invalid parameters in '--#{opt} #{fmt}'",
              "valid parameters are:", prm.merge(BASE_PARAMS).keys
  exit 1
end
# find out which parameters occur in the given header
# format and footer templates by omitting them one by one
# from the parameters and see if this reduced mapping
# is able to render the template; if not, the omitted
# parameter is proven to occur.
#current_header_keys, current_format_keys, current_footer_keys = [
current_keys = {
  header: [so.header || "", HEADER_PARAMS],
  format: [format,          FORMAT_PARAMS],
  footer: [so.footer || "", FORMAT_PARAMS],
}.transform_values { |fmt, prm|
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
# Arrange current keys in sets according to stages of filling them
# on course of visiting a file.
header_keys_in_use = current_keys.each_value.inject(:|) & BASE_PARAMS.merge(HEADER_PARAMS).keys
format_noheader_keys,footer_noheader_keys = current_keys.values_at(:format, :footer).map { |ka| ka - header_keys_in_use }
# amend above sets by transferring indices from footer, as we don't want to
# update indices for footer (footer is like a stealth match for last line --
# matches but not counted)
indices = %i[idx idx0 idx1 IDX IDX0 IDX1]
footer_indices = current_keys[:footer] & indices
format_keys_final = format_noheader_keys | footer_indices
footer_noheader_noindex_keys = footer_noheader_keys - footer_indices

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
winsiz = ([so.footer ? 1 : 0, bottom] + regexen.map { |rx| rx[:down] }).compact.map(&:abs).max

Signal.trap("SIGPIPE", "SYSTEM_DEFAULT")

writer = so.force_end.map { |e|
  case e
  when "cleartty"
    STDOUT.isatty ? "clear" : nil
  else
    e
  end
}.compact.sort.uniq.then { |force_end|
  case force_end
  when []
    STDOUT.method :print
  when %w[newline]
    STDOUT.method :puts
  when %w[clear]
    ->(arg) { print arg + BASE_PARAMS[:CLR] }
  when %w[clear newline]
    ->(arg) { puts arg.chomp + BASE_PARAMS[:CLR] }
  else
    STDERR.puts "unknown ending spec: #{force_end - %w[clear newline]}"
    exit 1
  end
}

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

    format_line = proc do |keys, fmt, ln, shift|
      if idx.zero?
        header_keys_in_use.each { |k|
          formath[k] = case k
          when :NL,:TAB,:NUL,:BLACK,:RED,:GREEN,:YELLOW,:BLUE,:MAGENTA,:CYAN,:WHITE,:CLR
            BASE_PARAMS[k]
          when :path
            fn
          when :file
            File.basename(fn)
          when :dir
            File.dirname(fn)
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
        so.header and writer.(so.header % formath)
        fidx += 1
      end

      lno = lineno - shift
      keys.each { |k|
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
        when :chomp
          ln.chomp
        when :strip
          ln.strip
        when :rstrip
          ln.rstrip
        when :lstrip
          ln.lstrip
        when :dump
          ln.dump
        when :json
          ln.to_json
        when :len
          ln.chomp.size
        when :match
          (matches[lineno - shift]||[]).first
        when :matches
          (matches[lineno - shift]||[]).map(&:dump).join ?,
        else
          raise "bad formatter key #{k.inspect}"
        end
      }
      if so.delimit_hunks and last_lno and last_lno < lno - 1
        puts "--"
      end
      writer.(fmt % formath)
      global_idx +=1
      idx += 1
      last_lno = lno
    end

    pos_ranges_current = pos_ranges.dup
    window = []
    fh.each do |line|
      window << line
      regexen.each { |rx|
        if
          rx[:subs] ? line.gsub!(rx[:rx], rx[:subs]) : rx[:rx] =~ line
        then
          (matches[lineno]||=[]) << $&
        end
        if rx[:inverse] == !$~
          # insert ad hoc item for match neighborhood so that we preserve
          # order (no need for bsearch as item will likely inserted
          # close to beginning)
          up = lineno + rx[:up]
          i = pos_ranges_current.index { |r| up < r.begin } || pos_ranges_current.size
          pos_ranges_current.insert i, [lineno + rx[:down], 0].max..up
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
          format_line[format_keys_final, format, outline, winsiz]
        end
      end
      [pos_ranges_current, neg_ranges, regexen].all? { |ra| ra.empty? } and !so.footer and break
      # drop match record for a line known to be out of the window
      matches.size > winsiz and matches.delete(matches.each_key.first)
      global_lineno += 1
      lineno += 1
    end

    # exhausted file, now negative indices can be
    # dereferenced in window, so decide about
    # lines in window, considering all ranges.
    window.each_with_index do |l,i|
      neglno = i - window.size
      shift = window.size - i
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
        format_line[format_keys_final, format, l, shift]
      end
    end
    if so.footer and idx > 0
      format_line[footer_noheader_noindex_keys, so.footer, window.last, 1]
      # footer is 'sthealth match', have to set back global_idx
      # to pretend as we were not run. (idx is also captured but its
      # scope ends here so that does not matter.)
      global_idx -= 1
    end

  end
end
