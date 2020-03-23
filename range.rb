#!/usr/bin/env ruby

ra = $*.map { |a|
  a.split(/\s*,\s*/).map { |b|
    Range.new *case b
    when /\A(\d+)\Z/
      Integer($1).then {|n| [n,n,false] }
    when /\A(\d+)\.\.(\.)?(\d+)?\Z/
      [$1,$3].map{|s| s ? Integer(s) : nil} + [!!$2]
    when /\A\.\.(\.)?(\d+)\Z/
      [nil, Integer($2), !!$1]
    else raise ArgumentError, "cannot interpret #{b.inspect} as range"
    end
  }
}.flatten

STDIN.each_with_index { |l,i|
  ra.find { |r| r.include? i+1 } and print l
}
