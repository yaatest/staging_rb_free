#!/usr/bin/env ruby

require 'timeout'
require 'colorized_string'
require 'net/ntp'

$ntp_srvs   = ['pool.ntp.org',
               'ololo.ntp.hui',
               'pool3.ntp.org',
               'time.google.com']
$port       = 123

Ntp_timeout = 1 

def ntp_service_works?(host, port = $port)
  @host = host
  @port = port 
    
  begin
    Timeout::timeout(Ntp_timeout) do
      Net::NTP.get(@host, @port)
      return true
    end
  rescue 
    return false
  end
end

def srvs_reachable(ntp_srvs)
  ntp_srvs.each do |srv|
    @report = lambda do |res,col|
      @col  = col
      printf "%-50s %30s\n", "* #{@host}:#{@port}", ColorizedString[res].colorize(:color => @col)
    end

    case ntp_service_works?(srv)
      when true
        @report.call("reachable",   :green)
      else 
        @report.call("unreachable", :red)
      end
  end
end

srvs_reachable($ntp_srvs)
