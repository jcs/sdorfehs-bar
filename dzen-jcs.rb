#!/usr/bin/ruby
#
# a script to gather data on an openbsd laptop and pipe it to dzen2
#
# Copyright (c) 2009, 2010 joshua stein <jcs@jcs.org>
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

# config (TODO: pull these from a config file)

# color of disabled text
DISABLED = "#aaa"

# dzen bar height
HEIGHT = 17

# hours for fuzzy clock
HOURS = [ "midnight", "one", "two", "three", "four", "five", "six", "seven",
  "eight", "nine", "ten", "eleven", "noon", "thirteen", "fourteen", "fifteen",
  "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "twenty-one",
  "twenty-two", "twenty-three" ]

# minimum temperature (f) at which sensors will be shown
TEMP_MIN = 115

# zipcode to fetch weather for
WEATHER_ZIP = "85716"

# wireless interface
WIFI_IF = "iwn0"

# pidgin status id->string->color mapping (not available through dbus)
PIDGIN_STATUSES = {
  1 => { :s => "offline", :c => DISABLED },
  2 => { :s => "available", :c => "green" },
  3 => { :s => "unavailable", :c => "yellow" },
  4 => { :s => "invisible", :c => "#cccccc" },
  5 => { :s => "away", :c => "#cccccc" },
  6 => { :s => "ext away", :c => "#cccccc" },
}

# helpers

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

@cache = {}
def update_every(seconds)
  c = caller_method_name
  @cache[c] ||= { :last => nil, :data => nil, :error => nil }

  if (@cache[c][:error] && (Time.now.to_i - @cache[c][:error] > 15)) ||
  !@cache[c][:last] || (Time.now.to_i - @cache[c][:last] > seconds)
    begin
      @cache[c][:data] = yield
      @cache[c][:error] = nil
    rescue
      @cache[c][:data] = "error"
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

    b = IO.popen("/usr/local/sbin/btconfig")
    b.readlines.each do |sc|
      if sc.match(/ubt\d/)
        up = true
      end
    end
    b.close

    "^fg(#{up ? '' : DISABLED})bt^fg()"
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
    @dbus_session ||= DBus::SessionBus.instance

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

      sh = PIDGIN_STATUSES[@dbus_pidgin.PurpleSavedstatusGetType(status).first]

      "^fg(#{sh[:c]})#{sh[:s]}^fg()" +
        (unread > 0 ? " ^fg(yellow)(#{unread} unread)^fg()" : "")
    else
      @dbus_purple = @dbus_pidgin = nil

      "^fg(#{DISABLED})offline^fg()"
    end
  end
end

# show the ac status, then each battery's percentage of power left
def power
  update_every(5) do
    batt_max = batt_left = batt_perc = {}, {}, {}
    ac_on = false

    s = IO.popen("/usr/sbin/sysctl hw.sensors.acpibat0 hw.sensors.acpibat1 " +
      "hw.sensors.acpiac0")
    s.readlines.each do |sc|
      if m = sc.match(/acpibat(\d)\.watthour.=([\d\.]+) Wh .last full/)
        batt_max[m[1].to_i] = m[2].to_f
      elsif m = sc.match(/acpibat(\d)\.watthour.=([\d\.]+) Wh .remaining capacity/)
        batt_left[m[1].to_i] = m[2].to_f
      elsif m = sc.match(/acpiac.\.indicator0=On/)
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

    out = ""

    if ac_on
      out += "^fg(green)ac^fg(#{DISABLED})"
      batt_perc.keys.each do |i|
        out += sprintf("/%d%%", batt_perc[i])
      end
      out += "^fg()"
    else
      out = "^fg(#{DISABLED})ac^fg()"

      batt_perc.keys.each do |i|
        out += "^fg(#{DISABLED})/"

        if batt_perc[i] <= 10.0
          out += "^fg(red)"
        elsif batt_perc[i] < 30.0
          out += "^fg(yellow)"
        else
          out += "^fg(green)"
        end

        out += sprintf("%d%%", batt_perc[i]) + "^fg()"
      end
    end

    out
  end
end

# show any temperature sensors that are too hot
def temp
  update_every(30) do
    temps = []
    fanrpm = ""

    s = IO.popen("/usr/sbin/sysctl hw.sensors.acpithinkpad0")
    s.readlines.each do |sc|
      if m = sc.match(/temp\d=([\d\.]+) degC/)
        temps.push m[1].to_f
      elsif m = sc.match(/fan0=(\d+) /)
        fanrpm = m[1].to_i
      end
    end
    s.close

    m = 0.0
    temps.each{|t| m += t }
    fh = (9.0 / 5.0) * (m / temps.length.to_f) + 32.0

    if fh > TEMP_MIN
      "^fg(yellow)#{fh.to_i}^fg(#{DISABLED})f^fg()"
    else
      nil
    end
  end
end

# a fuzzy clock, always rounding up so i'm not late
def time
  update_every(1) do
    hour = HOURS[Time.now.hour]
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
        hour = HOURS[0]
      else
        hour = HOURS[Time.now.hour + 1]
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

# show the current/high temperature for today
def weather
  update_every(60 * 10) do
    w = ""

    xml = REXML::Document.new(Net::HTTP.get(
      URI.parse("http://www.google.com/ig/api?weather=#{WEATHER_ZIP}")))

    w = xml.elements["xml_api_reply"].elements["weather"].
      elements["current_conditions"].elements["condition"].
      attributes["data"].downcase

    w += "^fg() " + xml.elements["xml_api_reply"].
      elements["weather"].elements["current_conditions"].
      elements["temp_f"].attributes["data"] + "^fg(#{DISABLED})f^fg()"

    # don't bother trying to match the day name, just take the first one
    xml.elements["xml_api_reply"].elements["weather"].
    elements.each("forecast_conditions") do |fore|
      w += "^fg(#{DISABLED})/^fg()" +
        fore.elements["high"].attributes["data"] + "^fg(#{DISABLED})f^fg()"
      break
    end

    w
  end
end

# show the wireless interface status
def wireless
  update_every(30) do
    up, connected = false

    i = IO.popen("/sbin/ifconfig #{WIFI_IF} 2>&1")
    i.readlines.each do |sc|
      if sc.match(/flags=.*<UP,/)
        up = true
      elsif sc.match(/status: active/)
        connected = true
      end
    end
    i.close

    "^fg(#{up ? (connected ? 'green' : '') : DISABLED})wifi^fg()"
  end
end

# separator bar
def sep
  "^fg(black)^r(8x1)^fg(#888888)^r(1x#{HEIGHT.to_f/1.35})^fg(black)^r(8x1)^fg()"
end

def kill_dzen2
  if $dzen
    Process.kill(9, $dzen.pid)
  end
  exit
rescue
end

# kill dzen2 if we die
Kernel.trap("QUIT", "kill_dzen2")
Kernel.trap("TERM", "kill_dzen2")
Kernel.trap("INT", "kill_dzen2")

# the guts
$dzen = IO.popen("dzen2 -w 700 -x -700 -bg black -fg white -ta r " +
  "-h #{HEIGHT} -fn '*-proggytinysz-medium-' -p", "w+")
while $dzen do
  $dzen.puts [
    pidgin,
    weather,
    temp,
    power,
    bluetooth,
    wireless,
    time,
    date
  ].reject{|part| !part }.join(sep) + "  "

  sleep 1
end
