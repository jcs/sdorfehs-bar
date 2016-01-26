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

config = {
  # seconds to blink on and off during 1 second
  :blink => [ 0.85, 0.15 ],

  # dzen bar height
  :height => 40,

  # dzen bar witdh
  :width => 1500,

  # right-side padding
  :rightpadding => 25,

  # top padding
  :toppadding => 4,

  # font for dzen to use
  :font => "dejavu sans mono:size=10",

  :colors => {
    :bg => `ratpoison -c 'set bgcolor'`.strip,
    :fg => `ratpoison -c 'set fgcolor'`.strip,
    :notification => "white",
    :notification_title => "yellow",
    :disabled => "#90A1AD",
    :sep => "#7E94A3",
    :ok => "#87DE99",
    :warn => "orange",
    :alert => "#D2DE87",
    :emerg => "red",
  },

  # minimum temperature (f) at which sensors will be shown
  :temp_min => 155,

  # zipcode to fetch weather for
  :weather_zip => "60622",

  # stocks symbols to watch
  :stocks => {},

  # which modules are enabled, and in which order
  :module_order => [ :weather, :temp, :power, :network, :audio, :time, :date ],


  # for dbus notification integration
  :dbus_notifications => true,

  # font for notifications
  :notification_font => "dejavu sans mono:size=11:weight=bold",

  # time to sleep while showing a notification
  :notification_wait => 5,
}

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

class Dzen
  attr_reader :config
  attr_writer :dying

  def initialize(config)
    @config = config
    @cache = {}
    @dzen = nil
    @i3status = nil

    @dying = false

    @notifications = []
    @semaphore = Mutex.new
  end

  def color(col)
    config[:colors][col]
  end

  def show(str)
    @dzen.puts str
  end

  def clense(str)
    # escape dzen control chars
    str.to_s.gsub(/\^/, "\\^").gsub("\n", " ").gsub("\r", "")
  end

  def show_notification(title, notification)
    max_len = 150

    title = clense(title)
    notification = clense(notification)

    if title.length > max_len
      title = title[0, max_len - 50]
      notification = notification[0, 50]
    else
      notification = notification[0, max_len - title.length]
    end

    @semaphore.synchronize {
      @notifications.push "^fn(#{config[:notification_font]})" <<
        "^fg(#{color(:notification_title)})#{title}: " <<
        "^fg(#{color(:notification)})#{notification}" <<
        "^fg()^fn(#{config[:font]})"
    }
  end

  def run!
    if !File.exists?("/usr/local/bin/i3status")
      STDERR.puts "i3status not found"
      exit 1
    end

    # find the screen resolution so we can pass a proper -x value to dzen2
    # (newer versions can do -x -700)
    screenwidth = `/usr/X11R6/bin/xwininfo -root`.split("\n").select{|l|
      l.match(/-geometry/) }.first.to_s.gsub(/.* /, "").gsub(/x.*/, "").to_i
    if screenwidth == 0
      STDERR.puts "can't find root geometry"
      exit 1
    end

    # bring up a writer to dzen
    @dzen = IO.popen([
      "dzen2",
      "-dock",
      "-x", (screenwidth - config[:width] - config[:rightpadding]).to_s,
      "-w", config[:width].to_s,
      "-y", config[:toppadding].to_s,
      "-bg", color(:bg),
      "-fg", color(:fg),
      "-ta", "r",
      "-h", config[:height].to_s,
      "-fn", config[:font],
      "-p"
    ], "w+")

    # and a reader from i3status
    @i3status_cache = {}
    @i3status = IO.popen("/usr/local/bin/i3status", "r+")

    # it may take a while for components to start up and cache things, so tell
    # the user
    self.show "^fg(#{color(:alert)}) starting up ^fg()"

    while @dzen do
      if @dying || IO.select([ @dzen ], nil, nil, 0.1)
        cleanup
        exit
      end

      @semaphore.synchronize {
        while @notifications.any?
          self.show @notifications.shift
          sleep config[:notification_wait]
        end
      }

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
      output = config[:module_order].map{|a| eval(a.to_s) }.
        reject{|part| !part }.join(sep)

      # handle ^blink() internally
      if output.match(/\^blink\(/)
        output, dark = unblink(output)

        # flash output, darken it for a brief moment, then show it again
        self.show output
        sleep config[:blink].first
        self.show dark
        sleep config[:blink].last
        self.show output
      else
        self.show output

        sleep 1
      end
    end
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

  # find ^blink() strings and return a stripped out version and a dark version
  # (a regular gsub won't work because we have to track parens)
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
        dark_str << m[1] << "^fg(#{color(:disabled)})"

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

      present ? "^fg(#{color(up ? :ok : :disabled)})bt^fg()" : nil
    end
  end

  # show the date
  def date
    update_every do
      # no strftime arg for date without leading zero :(
      (Time.now.strftime("%A #{Date.today.day.to_s} %b")).downcase
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
        out << "^fg(#{color(:ok)})ac" <<
          "^fg(#{color(:disabled)})"
        batt_perc.keys.each do |i|
          out << sprintf("/%d%%", batt_perc[i])
        end
        out << "^fg()"
      else
        out = "^fg(#{color(:disabled)})ac^fg()"

        total_perc = batt_perc.values.inject{|a,b| a + b }

        batt_perc.keys.each do |i|
          out << "^fg(#{color(:disabled)})/"

          blink = false
          if batt_perc[i] <= 10.0
            out << "^fg(#{color(:emerg)})"
            if total_perc < 10.0
              blink = true
            end
          elsif batt_perc[i] < 30.0
            out << "^fg(#{color(:alert)})"
          else
            out << "^fg(#{color(:ok)})"
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
      if config[:stocks].any?
        sd = Net::HTTP.get(URI.parse("http://download.finance.yahoo.com/d/" +
          "quotes.csv?s=" + config[:stocks].keys.join("+") + "&f=sp2l1"))

        out = []
        sd.split("\r\n").each do |line|
          ticker, change, quote = line.split(",").map{|z| z.gsub(/"/, "") }

          quote = sprintf("%0.2f", quote.to_f)
          change = change.gsub(/%/, "").to_f

          color = ""
          if quote.to_f >= config[:stocks][ticker].to_f
            color = color(:alert)
          elsif change > 0.0
            color = color(:ok)
          elsif change < 0.0
            color = color(:emerg)
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

      if fh > config[:temp_min]
        "^fg(#{color(:alert)})^blink(#{fh.to_i})^fg(#{color(:disabled)})f^fg()"
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
        "http://weather.yahooapis.com/forecastrss?p=#{config[:weather_zip]}")))

      w << xml.elements["rss"].elements["channel"].elements["item"].
        elements["yweather:condition"].attributes["text"].downcase

      # add current temperature
      w << " ^fg()" << (xml.elements["rss"].elements["channel"].elements["item"].
        elements["yweather:condition"].attributes["temp"]) <<
        "^fg(#{color(:disabled)})f^fg()"

      # add current humidity
      humidity = xml.elements["rss"].elements["channel"].
        elements["yweather:atmosphere"].attributes["humidity"].to_i
      w << "^fg(#{color(:disabled)})/^fg(" <<
        (humidity > 60 ? color(:alert) : "") <<
        ")" << humidity.to_s << "^fg(#{color(:disabled)})%^fg()"

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
          wi << "^fg(#{color(:ok)})"
        elsif wifi_signal >= 50
          wi << "^fg(#{color(:alert)})"
        else
          wi << "^fg(#{color(:warn)})"
        end

        wi << "wifi^fg()"
      elsif wifi_connected
        wi = "^fg(#{color(:ok)})wifi^fg()"
      elsif wifi_up
        wi = "^fg(#{color(:disabled)})wifi^fg()"
      end

      if eth_connected
        eth = "^fg(#{color(:ok)})eth^fg()"
      end

      out = nil
      if wi != ""
        out = wi
      end
      if eth != ""
        if out
          out << "^fg(#{color(:disabled)}), " << eth
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
      o = "^fg(#{color(:disabled)})vol/"

      if @i3status_cache[:volume].match(/mute/)
        o << "---"
      else
        o << "^fg(#{color(:ok)})" << @i3status_cache[:volume]
      end

      o << "^fg()"
      o
    end
  end

  # separator bar
  def sep
    "   "
  end
end

class NotificationService < DBus::Object
  def dzen=(dzen)
    @dzen = dzen
  end

  # conforms to https://developer.gnome.org/notification-spec/
  dbus_interface "org.freedesktop.Notifications" do
    # susssasa{sv}i
    dbus_method :Notify, [
    "in app_name:s",
    "in replaces_id:u",
    "in app_icon:s",
    "in summary:s",
    "in body:s",
    "in actions:as",
    "in hints:a{sv}",
    "in expire_timeout:i" ].join(", ") do |app_name, replaces_id, app_icon,
    summary, body, actions, hints, expire_timeout|
      @dzen.show_notification(summary.to_s == "" ? app_name : summary, body)
    end

    dbus_method :CloseNotification, "in id:u" do |*args|
      # ignore for now
    end

    dbus_method :GetServerInformation, [
    "out name:s",
    "out vendor:s",
    "out version:s",
    "out spec_version:s" ].join(", ") do |*args|
      [ "dzen-jcs", "jcs", "1", "1.0" ]
    end

    dbus_method :GetCapabilities, "out return_caps:as" do |*args|
      [
        [ "action-icons", "actions", "body", "body-hyperlinks", "body-images",
          "body-markup", "icon-multi", "icon-static", "persistence", "sound" ]
      ]
    end
  end
end

@dzen = Dzen.new(config)

# try to take dzen2 and i3status down with us
[ "QUIT", "TERM", "INT" ].each{|sig| Kernel.trap(sig) { @dzen.dying = true } }

if config[:dbus_notifications]
  # start listening for dbus notifications
  Thread.abort_on_exception = true
  Thread.new {
    dbus = DBus::SessionBus.instance
    service = dbus.request_service("org.freedesktop.Notifications")
    ns = NotificationService.new("/org/freedesktop/Notifications")
    ns.dzen = @dzen
    service.export(ns)

    dbusloop = DBus::Main.new
    dbusloop << dbus
    dbusloop.run
  }
end

# on with the show
@dzen.run!
