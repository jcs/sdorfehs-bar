#!/usr/bin/env ruby
#
# Copyright (c) 2009-2015 joshua stein <jcs@jcs.org>
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

@config = {}

# seconds to blink on and off during 1 second
@config[:blink] = [ 0.85, 0.15 ]

# dzen bar height
@config[:height] = 40

# right-side padding
@config[:rightpadding] = 25

# top padding
@config[:toppadding] = 4

# font for dzen to use
@config[:font] = "dejavu sans mono:size=10"

@config[:colors] = {
  :bg => `ratpoison -c 'set bgcolor'`.strip,
  :fg => `ratpoison -c 'set fgcolor'`.strip,
  :disabled => "#90A1AD",
  :sep => "#7E94A3",
  :ok => "#87DE99",
  :warn => "orange",
  :alert => "#D2DE87",
  :emerg => "darkred",
}

# minimum temperature (f) at which sensors will be shown
@config[:temp_min] = 155

# zipcode to fetch weather for
@config[:weather_zip] = "60622"

# stocks symbols to watch
@config[:stocks] = {}

# pidgin status id->string->color mapping (not available through dbus)
@config[:pidgin_statuses] = {
  1 => { :s => "offline", :c => @config[:colors][:disabled] },
  2 => { :s => "available", :c => @config[:colors][:ok] },
  3 => { :s => "unavailable", :c => @config[:colors][:alert] },
  4 => { :s => "invisible", :c => "#cccccc" },
  5 => { :s => "away", :c => "#cccccc" },
  6 => { :s => "ext away", :c => "#cccccc" },
}

# which modules are enabled, and in which order
@config[:module_order] = [ :weather, :temp, :power, :network, :audio, :time,
  :date ]

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
      dark_str << m[1] << "^fg(#{@config[:colors][:disabled]})"

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
def update_every(seconds = 1)
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
      STDERR.puts e.inspect, e.backtrace
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

    present ? "^fg(#{@config[:colors][up ? :ok : :disabled]})bt^fg()" : nil
  end
end

# show the date
def date
  update_every do
    # no strftime arg for date without leading zero :(
    (Time.now.strftime("%A #{Date.today.day.to_s} %b")).downcase
  end
end

# if pidgin is running, show the away/available status, and whether there are
# any unread messages pending
def pidgin
  update_every do
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

      sh = @config[:pidgin_statuses][
        @dbus_pidgin.PurpleSavedstatusGetType(status).first]

      "^fg(#{sh[:c]})#{sh[:s]}^fg()" <<
        (unread > 0 ? " ^fg(#{@config[:colors][:alert]})" <<
        "^blink((#{unread} unread))^fg()" : "")
    else
      @dbus_purple = @dbus_pidgin = nil

      "^fg(#{@config[:colors][:disabled]})offline^fg()"
    end
  end
end

# show the ac status, then each battery's percentage of power left
def power
  update_every do
    batt_max = batt_left = batt_perc = {}, {}, {}
    ac_on = false

    if m = @i3status_cache[:battery].match(/^(CHR|BAT)\|(\d*)%/)
      ac_on = (m[1] == "CHR")
      batt_perc = { 0 => m[2].to_i }
    end

    out = ""

    if ac_on
      out << "^fg(#{@config[:colors][:ok]})ac" <<
        "^fg(#{@config[:colors][:disabled]})"
      batt_perc.keys.each do |i|
        out << sprintf("/%d%%", batt_perc[i])
      end
      out << "^fg()"
    else
      out = "^fg(#{@config[:colors][:disabled]})ac^fg()"

      total_perc = batt_perc.values.inject{|a,b| a + b }

      batt_perc.keys.each do |i|
        out << "^fg(#{@config[:colors][:disabled]})/"

        blink = false
        if batt_perc[i] <= 10.0
          out << "^fg(#{@config[:colors][:emerg]})"
          if total_perc < 10.0
            blink = true
          end
        elsif batt_perc[i] < 30.0
          out << "^fg(#{@config[:colors][:alert]})"
        else
          out << "^fg(#{@config[:colors][:ok]})"
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
    if @config[:stocks].any?
      sd = Net::HTTP.get(URI.parse("http://download.finance.yahoo.com/d/" +
        "quotes.csv?s=" + @config[:stocks].keys.join("+") + "&f=sp2l1"))

      out = []
      sd.split("\r\n").each do |line|
        ticker, change, quote = line.split(",").map{|z| z.gsub(/"/, "") }

        quote = sprintf("%0.2f", quote.to_f)
        change = change.gsub(/%/, "").to_f

        color = ""
        if quote.to_f >= @config[:stocks][ticker].to_f
          color = @config[:colors][:alert]
        elsif change > 0.0
          color = @config[:colors][:ok]
        elsif change < 0.0
          color = @config[:colors][:emerg]
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
  update_every do
    temps = []

    if @i3status_cache[:cpu_temperature]
      temps.push @i3status_cache[:cpu_temperature].to_f
    end

    m = 0.0
    temps.each{|t| m += t }
    fh = (9.0 / 5.0) * (m / temps.length.to_f) + 32.0

    if fh > @config[:temp_min]
      "^fg(#{@config[:colors][:alert]})^blink(#{fh.to_i})" <<
        "^fg(#{@config[:colors][:disabled]})f^fg()"
    else
      nil
    end
  end
end

def time
  update_every do
    Time.now.strftime("%H:%M")
  end
end

# show the current/high temperature for today
def weather
  update_every(60 * 10) do
    w = ""

    xml = REXML::Document.new(Net::HTTP.get(URI.parse(
      "http://weather.yahooapis.com/forecastrss?p=#{@config[:weather_zip]}")))

    w << xml.elements["rss"].elements["channel"].elements["item"].
      elements["yweather:condition"].attributes["text"].downcase

    # add current temperature
    w << " ^fg()" << (xml.elements["rss"].elements["channel"].elements["item"].
      elements["yweather:condition"].attributes["temp"]) <<
      "^fg(#{@config[:colors][:disabled]})f^fg()"

    # add current humidity
    humidity = xml.elements["rss"].elements["channel"].
      elements["yweather:atmosphere"].attributes["humidity"].to_i
    w << "^fg(#{@config[:colors][:disabled]})/^fg(" <<
      (humidity > 60 ? @config[:colors][:alert] : "") <<
      ")" << humidity.to_s << "^fg(#{@config[:colors][:disabled]})%^fg()"

    w
  end
end

# show the network interface status
def network
  update_every do
    wifi_up = false
    wifi_connected = false
    wifi_signal = 0
    eth_connected = false

    if m = @i3status_cache[:wireless].to_s.match(/^up\|(.+)$/)
      wifi_up = true

      if m[1] == "?"
        wifi_connected = false
      else
        wifi_connected = true
        if n = m[1].match(/(\d+)%/) # old
          wifi_signal = n[1].to_i
        elsif n = m[1].match(/(-?\d+) dBm/)
          wifi_signal = [ 2 * (n[1].to_i + 100), 100 ].min
        end
      end
    end

    if @i3status_cache[:ethernet].to_s.match(/up/)
      eth_connected = true
    end

    wi = ""
    eth = ""

    if wifi_connected && wifi_signal > 0
      if wifi_signal >= 75
        wi << "^fg(#{@config[:colors][:ok]})"
      elsif wifi_signal >= 50
        wi << "^fg(#{@config[:colors][:alert]})"
      else
        wi << "^fg(#{@config[:colors][:warn]})"
      end

      wi << "wifi^fg()"
    elsif wifi_connected
      wi = "^fg(#{@config[:colors][:ok]})wifi^fg()"
    elsif wifi_up
      wi = "^fg(#{@config[:colors][:disabled]})wifi^fg()"
    end

    if eth_connected
      eth = "^fg(#{@config[:colors][:ok]})eth^fg()"
    end

    out = nil
    if wi != ""
      out = wi
    end
    if eth != ""
      if out
        out << "^fg(#{@config[:colors][:disabled]}), " << eth
      else
        out = eth
      end
    end

    out
  end
end

# show the audio volume
def audio
  update_every do
    o = "^fg(#{@config[:colors][:disabled]})vol/"

    if @i3status_cache[:volume].match(/mute/)
      o << "---"
    else
      o << "^fg(#{@config[:colors][:ok]})" << @i3status_cache[:volume]
    end

    o << "^fg()"
    o
  end
end

# separator bar
def sep
  "^p(+16)^fg(#{@config[:colors][:sep]})^r(1x#{@config[:height].to_f/1.35})" <<
    "^p(+16)^fg()"
end

# kill dzen2/i3status when we die
def cleanup
  if @dzen
    Process.kill(9, @dzen.pid)
  end

  if @i3status
    Process.kill(9, @i3status.pid)
  end

  exit
rescue
end

Kernel.trap("QUIT", "cleanup")
Kernel.trap("TERM", "cleanup")
Kernel.trap("INT", "cleanup")

if !File.exists?("/usr/local/bin/i3status")
  STDERR.puts "i3status not found"
  exit 1
end

# find the screen resolution so we can pass a proper -x value to dzen2 (newer
# versions can do -x -700)
width = `/usr/X11R6/bin/xwininfo -root`.split("\n").select{|l|
  l.match(/-geometry/) }.first.to_s.gsub(/.* /, "").gsub(/x.*/, "").to_i
if width == 0
  width = 1366
end

# bring up a writer to dzen
@dzen = IO.popen([
  "dzen2",
  "-dock",
  "-x", (width - 900 - @config[:rightpadding]).to_s,
  "-w", "900",
  "-y", @config[:toppadding].to_s,
  "-bg", @config[:colors][:bg],
  "-fg", @config[:colors][:fg],
  "-ta", "r",
  "-h", @config[:height].to_s,
  "-fn", @config[:font],
  "-p"
], "w+")

# and a reader from i3status
@i3status_cache = {}
@i3status = IO.popen("/usr/local/bin/i3status", "r+")

# it may take a while for components to start up and cache things, so tell the
# user
@dzen.puts "^fg(#{@config[:colors][:alert]}) starting up ^fg()"

while @dzen do
  if IO.select([ @dzen ], nil, nil, 0.1)
    cleanup
    exit
  end

  # read all input from i3status, use last line of input
  while @i3status && IO.select([ @i3status ], nil, nil, 0.1)
    # [{"name":"wireless","instance":"iwn0","full_text":"up|166 dBm"},...
    if m = @i3status.gets.to_s.match(/^,?(\[\{.*)/)
      @i3status_cache = {}
      JSON.parse(m[1]).each do |mod|
        @i3status_cache[mod["name"].to_sym] = mod["full_text"]
      end
    end
  end

  # build output by concatting each module's output
  output = @config[:module_order].map{|a| eval(a.to_s) }.reject{|part| !part }.
    join(sep)

  # handle ^blink() internally
  if output.match(/\^blink\(/)
    output, dark = unblink(output)

    # flash output, darken it for a brief moment, then show it again
    @dzen.puts output
    sleep @config[:blink].first
    @dzen.puts dark
    sleep @config[:blink].last
    @dzen.puts output
  else
    @dzen.puts output

    sleep 1
  end
end
