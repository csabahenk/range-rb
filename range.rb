#!/usr/bin/env ruby

require_relative "../simpleopts.rb"

SOpt = SimpleOpts::Opt
so = SimpleOpts.get_args(["<rangexp...>",
                          {offset: 0, number: false, format: nil,
                           grep: SOpt.new(default: nil, type: Regexp),
                           final_newline: true}],
                          leftover_opts_key: :rangexp_candidates)
conv = proc { |n| Integer(n) - so.offset }

# Those args which were not recognized as options shall
# be now attempted to parse as range expressions.
# Along this, $* will be recreated to collect those args
# which fail this turn of parsing.
argv_remaining = so.rangexp_candidates + $*
$*.clear
ra = argv_remaining.map { |a|
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

format = so.format
if not format
  format = if so.number
    "%{idx} %{line}"
  else
    "%{line}"
  end
end
params = %i[line idx idx_raw match]
begin
  format % params.map { |pr| [pr, nil] }.to_h
rescue KeyError
  STDERR.puts "invalid parameters in '#{format}'",
              "valid parameters are: #{params.join " "}"
  exit 1
end

has_neg = ra.find { |r| %i[begin end].find {|m| (r.send(m)||0) < 0 }}

inp,ra = if has_neg
  lines = $<.readlines
  [lines, (0...lines.size).to_a.then {|a| ra.map {|r| a[r] }}]
else
  [$<, ra]
end

writer = so.final_newline ? :puts : :print
inp.each_with_index { |l,i|
  match = nil
  if ra.find { |r| r.include? i } or (
    if so.grep and l =~ so.grep
      match = $&
      true
    else
      false
    end
  )
    STDOUT.send writer, format % {line: l, idx: i + so.offset, idx_raw: i, match: match}
  end
}
