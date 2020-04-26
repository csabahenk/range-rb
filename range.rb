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

baseprm = {NL: "\n", TAB: "\t"}

format = so.format
if not format
  format = if so.number
    "%{lno} %{line}"
  else
    "%{line}"
  end
end
header_params = {path:"", file:"", fno:0, fno0:0, fno1:0}
[['format', format, {line: "", match:""}.merge(header_params).merge(
                     lno:0, lno0:0, lno1:0, LNO:0, LNO0:0, LNO1:0,
                     idx:0, idx0:0, idx1:0, IDX:0, IDX0:0, IDX1:0)],
 ['header', so.header || "", header_params]].each do |opt, fmt, prm|
  fmt % baseprm.merge(prm)
rescue KeyError
  STDERR.puts "invalid parameters in '--#{opt} #{fmt}'",
              "valid parameters are:", prm.merge(baseprm).keys
  exit 1
end

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
    fileh = baseprm.merge(path: fn, file: File.basename(fn), fno: fidx + so.offset, fno0: fidx, fno1: fidx + 1)
    so.header and puts so.header % fileh

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
        begin
          STDOUT.send writer, format % fileh.merge(lno: lineno + so.offset, lno0: lineno, lno1: lineno + 1,
                                                   LNO: global_lineno + so.offset, LNO0: global_lineno, LNO1: global_lineno + 1,
                                                   idx: idx + so.offset, idx0: idx, idx1: idx + 1,
                                                   IDX: global_idx + so.offset, IDX0: global_idx, IDX1: global_idx + 1,
                                                   line: line, match: match)
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
