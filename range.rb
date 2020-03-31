#!/usr/bin/env ruby

require File.expand_path "~/ruby/simpleopts/simpleopts.rb"

so = SimpleOpts.get("<rangexp...>", offset: 0)
conv = proc { |n| Integer(n) - so.offset }

ra = $*.map { |a|
  a.split(/\s*,\s*/).map { |b|
    Range.new *case b
    when /\A(-?\d+)\Z/
      conv[$1].then {|n| [n,n,false] }
    when /\A(-?\d+)(?:(?:\.{2}|-)|(\.{3}))(-?\d+)?\Z/
      [$1,$3].map{|s| s ? conv[s] : nil} + [!!$2]
    when /\A\.\.(\.)?(-?\d+)\Z/
      [nil, conv[$2], !!$1]
    else raise ArgumentError, "cannot interpret #{b.inspect} as range"
    end
  }
}.flatten

has_neg = ra.find { |r| %i[begin end].find {|m| (r.send(m)||0) < 0 }}

inp,ra = if has_neg
  lines = STDIN.readlines
  [lines, (0...lines.size).to_a.then {|a| ra.map {|r| a[r] }}]
else
  [STDIN, ra]
end

inp.each_with_index { |l,i|
  ra.find { |r| r.include? i } and print l
}
