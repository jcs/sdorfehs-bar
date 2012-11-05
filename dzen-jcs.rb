#!/usr/bin/ruby
#
# a script to gather data on an openbsd laptop (optionally from i3status) and
# pipe it to dzen2
#
# Copyright (c) 2009-2012 joshua stein <jcs@jcs.org>
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
# 3. The name of the author may not be used to endorse or promote products
#    derived from this software without specific prior written permission.
# 
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
# IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
# NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
# THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

require "date"
require "dbus"
require "net/http"
require "rexml/document"
require "uri"
require "json"

$CONFIG = {}

# seconds to blink on and off during 1 second
$CONFIG[:blink] = [ 0.85, 0.15 ]

# color of disabled text
$CONFIG[:disabled] = "#aaa"

# dzen bar height
$CONFIG[:height] = 17

# font for dzen to use
$CONFIG[:font] = ""

# hours for fuzzy clock
$CONFIG[:hours] = [ "midnight", "one", "two", "three", "four", "five", "six",
  "seven", "eight", "nine", "ten", "eleven", "noon", "thirteen", "fourteen",
  "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty",
  "twenty-one", "twenty-two", "twenty-three" ]

# minimum temperature (f) at which sensors will be shown
$CONFIG[:temp_min] = 138

# zipcode to fetch weather for
$CONFIG[:weather_zip] = "60622"

# stocks symbols to watch
$CONFIG[:stocks] = {}

# wireless interface
$CONFIG[:wifi_device] = "iwn0"

# ethernet interface
$CONFIG[:eth_device] = "em0"

# pidgin status id->string->color mapping (not available through dbus)
$CONFIG[:pidgin_statuses] = {
  1 => { :s => "offline", :c => $CONFIG[:disabled] },
  2 => { :s => "available", :c => "green" },
  3 => { :s => "unavailable", :c => "yellow" },
  4 => { :s => "invisible", :c => "#cccccc" },
  5 => { :s => "away", :c => "#cccccc" },
  6 => { :s => "ext away", :c => "#cccccc" },
}

# whether to use i3status for temp, power, and wireless (avoids shelling out)
# requires an ~/.i3status.conf with:
# general {
#     output_format = "i3bar"
#     colors = false
#     interval = 5
# }
# 
# order += "wireless iwn0"
# order += "ethernet em0"
# order += "battery 0"
# order += "cpu_temperature acpithinkpad0"
# 
# cpu_temperature acpithinkpad0 {
#     format = "%degrees"
# }
# 
# wireless iwn0 {
#     format_up = "up|%signal"
#     format_down = "down"
# }
# 
# ethernet em0 {
#     format_up = "up"
#     format_down = "down"
# }
# 
# battery 0 {
#     format = "%status|%percentage"
# }
$CONFIG[:use_i3status] = File.exists?("/usr/local/bin/i3status")

# how often i3status is setup to report; with this we can override longer poll
# times for network and power since we'll have more accurate info sooner at no
# cost to us
$CONFIG[:i3status_poll] = 5

# which modules are enabled, and in which order
$CONFIG[:module_order] = [ :weather, :stocks, :temp, :power, :network, :time,
  :date ]

# override defaults by eval'ing ~/.dzen-jcs.rb
if File.exists?(f = "#{ENV['HOME']}/.dzen-jcs.rb")
  eval(File.read(f))
end

# helpers

class NilClass
  def any?
    false
  end
end

class String
  def any?
    !empty?
  end
end

def caller_method_name
  parse_caller(caller(2).first).last
end

def parse_caller(at)
  if /^(.+?):(\d+)(?::in `(.*)')?/ =~ at
    file = Regexp.last_match[1]
    line = Regexp.last_match[2].to_i
    method = Regexp.last_match[3]
    [file, line, method]
  end
end

# find ^blink() strings and return a stripped out version and a dark version (a
# regular gsub won't work because we have to track parens)
def unblink(str)
  new_str = ""
  dark_str = ""

  chunk = ""
  x = 0
  while x < str.length
    chunk << str[x .. x]
    x += 1

    if m = chunk.match(/^(.*)\^blink\($/)
      new_str << m[1]
      dark_str << m[1] << "^fg(#{$CONFIG[:disabled]})"

      # keep eating characters until we see the closing )
      opens = 0
      while x < str.length
        chr = str[x .. x]
        x += 1

        if chr == "("
          opens += 1
        elsif chr == ")"
          if opens == 0
            break
          else
            opens -= 1
          end
        end

        new_str << chr
        dark_str << chr
      end

      dark_str << "^fg()"
      chunk = ""
    end
  end

  if chunk != ""
    new_str << chunk
    dark_str << chunk
  end

  return [ new_str, dark_str ]
end

@cache = {}
def update_every(seconds)
  c = caller_method_name
  @cache[c] ||= { :last => nil, :data => nil, :error => nil }

  if (@cache[c][:error] && (Time.now.to_i - @cache[c][:error] > 15)) ||
  !@cache[c][:last] || (Time.now.to_i - @cache[c][:last] > seconds)
    begin
      @cache[c][:data] = yield
      @cache[c][:error] = nil
    rescue Timeout::Error
      @cache[c][:data] = "error"
      @cache[c][:error] = Time.now.to_i
    rescue StandardError => e
      @cache[c][:data] = "error: #{e.inspect}"
      STDERR.puts e.backtrace
      @cache[c][:error] = Time.now.to_i
    end
    @cache[c][:last] = Time.now.to_i
  end

  @cache[c][:data]
end

# data-collection routines

# show the bluetooth interface status
def bluetooth
  update_every(30) do
    up = false
    present = false

    b = IO.popen("/usr/local/sbin/btconfig")
    b.readlines.each do |sc|
      if sc.match(/ubt\d/)
        present = true
        if sc.match(/UP/)
          up = true
        end
      end
    end
    b.close

    present ? "^fg(#{up ? 'green' : $CONFIG[:disabled]})bt^fg()" : nil
  end
end

# show the date
def date
  update_every(1) do
    # no strftime arg for date without leading zero :(
    (Time.now.strftime("%A #{Date.today.day.to_s} %b")).downcase
  end
end

# a fuzzy clock, always rounding up so i'm not late
def fuzzy_time
  update_every(1) do
    hour = $CONFIG[:hours][Time.now.hour]
    mins = Time.now.min

    case mins
    when 0 .. 2
      hour + (hour.match(/midnight|noon/) ? "" : " hour" +
        (hour == "one" ? "" : "s"))
    when 3 .. 7
      "five past #{hour}"
    when 8 .. 11
      "ten past #{hour}"
    when 12 .. 17
      "quarter past #{hour}"
    when 16 .. 21
      "twenty past #{hour}"
    when 22 .. 36
      "half past #{hour}"
    when 37 .. 40
      "forty past #{hour}"
    else
      if Time.now.hour == 23
        hour = $CONFIG[:hours][0]
      else
        hour = $CONFIG[:hours][Time.now.hour + 1]
      end

      case mins
      when 41 .. 49
        "quarter to #{hour}"
      when 50 .. 53
        "ten to #{hour}"
      when 54 .. 55
        "five to #{hour}"
      else
        hour + (hour.match(/midnight|noon/) ? "" : " hour" +
          (hour == "one" ? "" : "s"))
      end
    end
  end
end

# if pidgin is running, show the away/available status, and whether there are
# any unread messages pending
def pidgin
  update_every(1) do
    begin
      @dbus_session ||= DBus::SessionBus.instance
    rescue => e
      if e.message.match(/undefined method .split/)
        return "error: dbus not running"
      else
        raise e
      end
    end

    # check whether pidgin is running first, otherwise talking to it will start
    # it up
    if @dbus_session.proxy.ListNames.first.
    include?("im.pidgin.purple.PurpleService")
      @dbus_purple ||= @dbus_session.service("im.pidgin.purple.PurpleService")
      if !@dbus_pidgin
        @dbus_pidgin = @dbus_purple.object("/im/pidgin/purple/PurpleObject")
        @dbus_pidgin.default_iface = "im.pidgin.purple.PurpleInterface"
        @dbus_pidgin.introspect
      end

      status = @dbus_pidgin.PurpleSavedstatusGetCurrent.first
      unread = 0
      @dbus_pidgin.PurpleGetIms.first.each do |c|
        unread += @dbus_pidgin.PurpleConversationGetData(c, "unseen-count").first
      end

      sh = $CONFIG[:pidgin_statuses][
        @dbus_pidgin.PurpleSavedstatusGetType(status).first]

      "^fg(#{sh[:c]})#{sh[:s]}^fg()" +
        (unread > 0 ? " ^fg(yellow)^blink((#{unread} unread))^fg()" : "")
    else
      @dbus_purple = @dbus_pidgin = nil

      "^fg(#{$CONFIG[:disabled]})offline^fg()"
    end
  end
end

# show the ac status, then each battery's percentage of power left
def power
  update_every(5) do
    batt_max = batt_left = batt_perc = {}, {}, {}
    ac_on = false

    if $CONFIG[:use_i3status]
      if m = $i3status_cache[:battery].match(/^(CHR|BAT)\|(\d*)%/)
        ac_on = (m[1] == "CHR")
        batt_perc = { 0 => m[2].to_i }
      end
    else
      s = IO.popen("/usr/sbin/sysctl hw.sensors")
      s.readlines.each do |sc|
        if m = sc.match(/acpibat(\d)\.watthour.=([\d\.]+) Wh .last full/)
          batt_max[m[1].to_i] = m[2].to_f
        elsif m = sc.match(/acpibat(\d)\.watthour.=([\d\.]+) Wh .remaining cap/)
          batt_left[m[1].to_i] = m[2].to_f
        elsif sc.match(/acpiac.\.indicator0=On/)
          ac_on = true
        end
      end
      s.close

      batt_left.keys.each do |i|
        batt_perc[i] = (batt_left[i] / batt_max[i]) * 100.0

        if batt_perc[i] >= 99.5
          batt_perc[i] = 100
        end
      end
    end

    out = ""

    if ac_on
      out += "^fg(green)ac^fg(#{$CONFIG[:disabled]})"
      batt_perc.keys.each do |i|
        out += sprintf("/%d%%", batt_perc[i])
      end
      out += "^fg()"
    else
      out = "^fg(#{$CONFIG[:disabled]})ac^fg()"

      total_perc = batt_perc.values.inject{|a,b| a + b }

      batt_perc.keys.each do |i|
        out += "^fg(#{$CONFIG[:disabled]})/"

        blink = false
        if batt_perc[i] <= 10.0
          out += "^fg(red)"
          if total_perc < 10.0
            blink = true
          end
        elsif batt_perc[i] < 30.0
          out += "^fg(yellow)"
        else
          out += "^fg(green)"
        end

        out += (blink ? "^blink(" : "") +
          sprintf("%d%%", batt_perc[i]) + (blink ? ")" : "") + "^fg()"
      end
    end

    out
  end
end

def stocks
  update_every(60 * 5) do
    # TODO: check time, don't bother polling outside of market hours
    if $CONFIG[:stocks].any?
      sd = Net::HTTP.get(URI.parse("http://download.finance.yahoo.com/d/" +
        "quotes.csv?s=" + $CONFIG[:stocks].keys.join("+") + "&f=sp2l1"))

      out = []
      sd.split("\r\n").each do |line|
        ticker, change, quote = line.split(",").map{|z| z.gsub(/"/, "") }

        quote = sprintf("%0.2f", quote.to_f)
        change = change.gsub(/%/, "").to_f

        color = ""
        if quote.to_f >= $CONFIG[:stocks][ticker].to_f
          color = "yellow"
        elsif change > 0.0
          color = "green"
        elsif change < 0.0
          color = "red"
        end

        out.push "#{ticker} ^fg(#{color})#{quote}^fg()"
      end

      out.join(", ")
    else
      nil
    end
  end
end

# show any temperature sensors that are too hot
def temp
  update_every($CONFIG[:use_i3status] ? $CONFIG[:i3status_poll] : 30) do
    temps = []

    if $CONFIG[:use_i3status] && $i3status_cache[:cpu_temperature]
      temps.push $i3status_cache[:cpu_temperature].to_f
    else
      s = IO.popen("/usr/sbin/sysctl hw.sensors.acpitz0.temp0")
      s.readlines.each do |sc|
        if m = sc.match(/temp\d=([\d\.]+) degC/)
          temps.push m[1].to_f
        end
      end
      s.close
    end

    m = 0.0
    temps.each{|t| m += t }
    fh = (9.0 / 5.0) * (m / temps.length.to_f) + 32.0

    if fh > $CONFIG[:temp_min]
      "^fg(yellow)^blink(#{fh.to_i})^fg(#{$CONFIG[:disabled]})f^fg()"
    else
      nil
    end
  end
end

def time
  update_every(1) do
    Time.now.strftime("%H^blink(:)%M")
  end
end

# show the current/high temperature for today
def weather
  update_every(60 * 10) do
    w = ""

    xml = REXML::Document.new(Net::HTTP.get(URI.parse(
      "http://weather.yahooapis.com/forecastrss?p=#{$CONFIG[:weather_zip]}")))

    w = xml.elements["rss"].elements["channel"].elements["item"].
      elements["yweather:condition"].attributes["text"].downcase

    # add current temperature
    w += " ^fg()" + (xml.elements["rss"].elements["channel"].elements["item"].
      elements["yweather:condition"].attributes["temp"]) +
      "^fg(#{$CONFIG[:disabled]})f^fg()"

    # add current humidity
    humidity = xml.elements["rss"].elements["channel"].
      elements["yweather:atmosphere"].attributes["humidity"].to_i
    w += "^fg(#{$CONFIG[:disabled]})/^fg(" + (humidity > 60 ? "yellow" : "") +
      ")" + humidity.to_s + "^fg(#{$CONFIG[:disabled]})%^fg()"

    w
  end
end

# show the network interface status
def network
  update_every($CONFIG[:use_i3status] ? $CONFIG[:i3status_poll] : 30) do
    wifi_up = false
    wifi_connected = false
    eth_connected = false

    if $CONFIG[:use_i3status]
      if m = $i3status_cache[:wireless].to_s.match(/^up\|((\d+) dBm|\?)?$/)
        wifi_up = true
        wifi_connected = !(m[1] == "?")
        # TODO: show signal strength somehow?
      end

      if $i3status_cache[:ethernet].to_s.match(/up/)
        eth_connected = true
      end
    else
      [ :wifi_device, :eth_device ].each do |dev|
        i = IO.popen("/sbin/ifconfig #{$CONFIG[dev]} 2>&1")
        i.readlines.each do |sc|
          if sc.match(/flags=.*<UP,/) && dev == :wifi_device
            wifi_up = true
          elsif sc.match(/status: active/)
            if dev == :wifi_device
              wifi_connected = true
            else
              eth_connected = true
            end
          end
        end
        i.close
      end
    end

    if wifi_connected && eth_connected
      "^fg(green)wifi^fg(#{$CONFIG[:disabled]}), ^fg(green)eth^fg()"
    elsif wifi_connected
      "^fg(green)wifi^fg()"
    elsif wifi_up && eth_connected
      "^fg(#{$CONFIG[:disabled]})wifi, ^fg(green)eth^fg()"
    elsif wifi_up && !eth_connected
      "^fg(#{$CONFIG[:disabled]})wifi^fg()"
    elsif eth_connected
      "^fg(green)eth^fg()"
    else
      nil
    end
  end
end

# separator bar
def sep
  "^fg(black)^r(8x1)^fg(#888888)^r(1x#{$CONFIG[:height].to_f/1.35})" +
    "^fg(black)^r(8x1)^fg()"
end

# kill dzen2/i3status when we die
def cleanup
  if $dzen
    Process.kill(9, $dzen.pid)
  end

  if $i3status
    Process.kill(9, $i3status.pid)
  end

  exit
rescue
end

Kernel.trap("QUIT", "cleanup")
Kernel.trap("TERM", "cleanup")
Kernel.trap("INT", "cleanup")

# bring up a writer to dzen
$dzen = IO.popen([
  "dzen2",
  "-w", "700",
  "-x", "-700",
  "-bg", "black",
  "-fg", "white",
  "-ta", "r",
  "-h", $CONFIG[:height].to_s,
  "-fn", $CONFIG[:font].any? ? $CONFIG[:font] : "fixed",
  "-p"
], "w+")

# and a reader from i3status
$i3status = nil
$i3status_cache = {}
if $CONFIG[:use_i3status]
  $i3status = IO.popen("i3status", "r+")
end

# it may take a while for components to start up and cache things, so tell the
# user
$dzen.puts "^fg(yellow) starting up ^fg()"

while $dzen do
  # read all input from i3status, use last line of input
  if $i3status
    while IO.select([ $i3status ], nil, nil, 0.1)
      # [{"name":"wireless","instance":"iwn0","full_text":"up|166 dBm"},...
      if m = $i3status.gets.match(/^,?(\[\{.*)/)
        $i3status_cache = {}
        JSON.parse(m[1]).each do |mod|
          $i3status_cache[mod["name"].to_sym] = mod["full_text"]
        end
      end
    end
  end

  # build output by concatting each module's output
  output = $CONFIG[:module_order].map{|a| eval(a.to_s) }.reject{|part| !part }.
    join(sep) + "  "

  # handle ^blink() internally
  if output.match(/\^blink\(/)
    output, dark = unblink(output)

    # flash output, darken it for a brief moment, then show it again
    $dzen.puts output
    sleep $CONFIG[:blink].first
    $dzen.puts dark
    sleep $CONFIG[:blink].last
    $dzen.puts output
  else
    $dzen.puts output

    sleep 1
  end
end
