#!/usr/bin/env ruby
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

# dzen bar height
$CONFIG[:height] = 38

# font for dzen to use
$CONFIG[:font] = "dejavu sans mono:size=5.5"

$CONFIG[:colors] = {
  :bg => "black",
  :fg => "white",
  :disabled => "gray40",
  :sep => "#888",
  :ok => "green",
  :warn => "orange",
  :alert => "yellow",
  :emerg => "red",
}

# minimum temperature (f) at which sensors will be shown
$CONFIG[:temp_min] = 155

# zipcode to fetch weather for
$CONFIG[:weather_zip] = "60622"

# stocks symbols to watch
$CONFIG[:stocks] = {}

# wireless interface when not using i3status
$CONFIG[:wifi_device] = "iwn0"

# ethernet interface when not using i3status
$CONFIG[:eth_device] = "em0"

# pidgin status id->string->color mapping (not available through dbus)
$CONFIG[:pidgin_statuses] = {
  1 => { :s => "offline", :c => $CONFIG[:colors][:disabled] },
  2 => { :s => "available", :c => $CONFIG[:colors][:ok] },
  3 => { :s => "unavailable", :c => $CONFIG[:colors][:alert] },
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
      dark_str << m[1] << "^fg(#{$CONFIG[:colors][:disabled]})"

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

    present ? "^fg(#{up ? 'green' : $CONFIG[:colors][:disabled]})bt^fg()" : nil
  end
end

# show the date
def date
  update_every(1) do
    # no strftime arg for date without leading zero :(
    (Time.now.strftime("%A #{Date.today.day.to_s} %b")).downcase
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

      "^fg(#{sh[:c]})#{sh[:s]}^fg()" <<
        (unread > 0 ? " ^fg(#{$CONFIG[:colors][:alert]})" <<
        "^blink((#{unread} unread))^fg()" : "")
    else
      @dbus_purple = @dbus_pidgin = nil

      "^fg(#{$CONFIG[:colors][:disabled]})offline^fg()"
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
      out << "^fg(green)ac^fg(#{$CONFIG[:colors][:disabled]})"
      batt_perc.keys.each do |i|
        out << sprintf("/%d%%", batt_perc[i])
      end
      out << "^fg()"
    else
      out = "^fg(#{$CONFIG[:colors][:disabled]})ac^fg()"

      total_perc = batt_perc.values.inject{|a,b| a + b }

      batt_perc.keys.each do |i|
        out << "^fg(#{$CONFIG[:colors][:disabled]})/"

        blink = false
        if batt_perc[i] <= 10.0
          out << "^fg(#{$CONFIG[:colors][:emerg]})"
          if total_perc < 10.0
            blink = true
          end
        elsif batt_perc[i] < 30.0
          out << "^fg(#{$CONFIG[:colors][:alert]})"
        else
          out << "^fg(#{$CONFIG[:colors][:ok]})"
        end

        out << (blink ? "^blink(" : "") +
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
          color = $CONFIG[:colors][:alert]
        elsif change > 0.0
          color = $CONFIG[:colors][:ok]
        elsif change < 0.0
          color = $CONFIG[:colors][:emerg]
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
      "^fg(#{$CONFIG[:colors][:alert]})^blink(#{fh.to_i})" <<
        "^fg(#{$CONFIG[:colors][:disabled]})f^fg()"
    else
      nil
    end
  end
end

def time
  update_every(1) do
    Time.now.strftime("%H:%M")
  end
end

# show the current/high temperature for today
def weather
  update_every(60 * 10) do
    w = ""

    xml = REXML::Document.new(Net::HTTP.get(URI.parse(
      "http://weather.yahooapis.com/forecastrss?p=#{$CONFIG[:weather_zip]}")))

    w << xml.elements["rss"].elements["channel"].elements["item"].
      elements["yweather:condition"].attributes["text"].downcase

    # add current temperature
    w << " ^fg()" << (xml.elements["rss"].elements["channel"].elements["item"].
      elements["yweather:condition"].attributes["temp"]) <<
      "^fg(#{$CONFIG[:colors][:disabled]})f^fg()"

    # add current humidity
    humidity = xml.elements["rss"].elements["channel"].
      elements["yweather:atmosphere"].attributes["humidity"].to_i
    w << "^fg(#{$CONFIG[:colors][:disabled]})/^fg(" <<
      (humidity > 60 ? $CONFIG[:colors][:alert] : "") <<
      ")" << humidity.to_s << "^fg(#{$CONFIG[:colors][:disabled]})%^fg()"

    w
  end
end

# show the network interface status
def network
  update_every($CONFIG[:use_i3status] ? $CONFIG[:i3status_poll] : 30) do
    wifi_up = false
    wifi_connected = false
    wifi_signal = 0
    eth_connected = false

    if $CONFIG[:use_i3status]
      if m = $i3status_cache[:wireless].to_s.match(/^up\|(.+)$/)
        wifi_up = true

        if m[1] == "?"
          wifi_connected = false
        else
          wifi_connected = true
          if n = m[1].match(/(\d+)%/)
            wifi_signal = n[1].to_i
          end
        end
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
          elsif m = sc.match(/bssid [^ ]* (\d+)% /)
            wifi_signal = m[1].to_i
          end
        end
        i.close
      end
    end

    wi = ""
    eth = ""

    if wifi_connected
      wi = "^fg(green)wifi"

      if wifi_signal > 0
        wi << "^fg(#{$CONFIG[:disabled]})/"

        if wifi_signal >= 75
          wi << "^fg(#{$CONFIG[:colors][:ok]})"
        elsif wifi_signal >= 50
          wi << "^fg(#{$CONFIG[:colors][:alert]})"
        else
          wi << "^fg(#{$CONFIG[:colors][:warn]})"
        end
        # will probably never have 100% signal
        wi << sprintf("%2.0d", wifi_signal) <<
          "^fg(#{$CONFIG[:colors][:disabled]})%^fg()"
      end
    elsif wifi_up
      wi = "^fg(#{$CONFIG[:colors][:disabled]})wifi^fg()"
    end

    if eth_connected
      eth = "^fg(green)eth^fg()"
    end

    out = nil
    if wi != ""
      out = wi
    end
    if eth != ""
      if out
        out << "^fg(#{$CONFIG[:colors][:disabled]}), " << eth
      else
        out = eth
      end
    end

    out
  end
end

# separator bar
def sep
  "^fg(#{$CONFIG[:colors][:bg]})^r(16x1)^fg(#{$CONFIG[:colors][:sep]})" <<
    "^r(1x#{$CONFIG[:height].to_f/1.35})^fg(#{$CONFIG[:colors][:bg]})" <<
    "^r(16x1)^fg()"
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

# find the screen resolution so we can pass a proper -x value to dzen2 (newer
# versions can do -x -700)
width = `/usr/X11R6/bin/xwininfo -root`.split("\n").select{|l|
  l.match(/-geometry/) }.first.to_s.gsub(/.* /, "").gsub(/x.*/, "").to_i
if width == 0
  width = 1366
end

# bring up a writer to dzen
$dzen = IO.popen([
  "dzen2",
  "-x", (width - 700).to_s,
  "-w", "700",
  "-bg", $CONFIG[:colors][:bg],
  "-fg", $CONFIG[:colors][:fg],
  "-ta", "r",
  "-h", $CONFIG[:height].to_s,
  "-fn", $CONFIG[:font],
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
$dzen.puts "^fg(#{$CONFIG[:colors][:alert]}) starting up ^fg()"

while $dzen do
  if IO.select([ $dzen ], nil, nil, 0.1)
    cleanup
    exit
  end

  # read all input from i3status, use last line of input
  if $i3status
    while IO.select([ $i3status ], nil, nil, 0.1)
      # [{"name":"wireless","instance":"iwn0","full_text":"up|166 dBm"},...
      if m = $i3status.gets.to_s.match(/^,?(\[\{.*)/)
        $i3status_cache = {}
        JSON.parse(m[1]).each do |mod|
          $i3status_cache[mod["name"].to_sym] = mod["full_text"]
        end
      end
    end
  end

  # build output by concatting each module's output
  output = $CONFIG[:module_order].map{|a| eval(a.to_s) }.reject{|part| !part }.
    join(sep) << "  "

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
