#!/usr/bin/env ruby

ra = $*.map { |a|
  a.split(/\s*,\s*/).map { |b|
    Range.new *case b
    when /\A(-?\d+)\Z/
      Integer($1).then {|n| [n,n,false] }
    when /\A(-?\d+)(?:(?:\.{2}|-)|(\.{3}))(-?\d+)?\Z/
      [$1,$3].map{|s| s ? Integer(s) : nil} + [!!$2]
    when /\A\.\.(\.)?(-?\d+)\Z/
      [nil, Integer($2), !!$1]
    else raise ArgumentError, "cannot interpret #{b.inspect} as range"
    end
  }
}.flatten

has_neg = ra.find { |r| %i[begin end].find {|m| (r.send(m)||0) < 0 }}

inp,ra = if has_neg
  lines = STDIN.readlines
  [lines, (1..lines.size).to_a.then {|a| ra.map {|r| a[r] }}]
else
  [STDIN, ra]
end

inp.each_with_index { |l,i|
  ra.find { |r| r.include? i+1 } and print l
}
