#!/usr/bin/env ruby
#
# Copyright (c) 2009-2018 joshua stein <jcs@jcs.org>
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
require "net/https"
require "uri"
require "json"

def screenwidth
  `xrandr | grep '^Screen 0:'`.match(/.*current (\d+) x \d+/)[1].to_i
end

config = {
  # seconds to blink on and off during 1 second
  :blink => [ 0.85, 0.15 ],

  # dzen bar height
  :height => `ratpoison -c 'set padding'`.split(" ")[1].to_i - 1,

  # dzen bar width, half of the screen
  :width => screenwidth / 2,

  # right-side padding
  :rightpadding => `ratpoison -c 'set barpadding'`.split(" ")[0].to_i,

  # top padding
  :toppadding => 0,

  # font for dzen to use
  :font => `ratpoison -c 'set font'`.strip,

  :colors => {
    :bg => `ratpoison -c 'set bgcolor'`.strip,
    :fg => `ratpoison -c 'set fgcolor'`.strip,
    :disabled => "#90a1ad",
    :ok => "#87de99",
    :warn => "orange",
    :alert => "#d2de87",
    :emerg => "#ff7f7f",
  },

  # minimum temperature (f) at which sensors will be shown
  :temp_min => 160,

  # darksky.net api key used to fetch weather
  :weather_api_key => "",

  # lat and long for weather joined by a comma; if blank, an api will be used
  # to get the lat/long based on ip address
  :weather_lat_long => "",

  # cryptocurrencies to watch, as a hash of each symbol to a hash containing
  # the :qty and :cost of amounts held
  # https://www.cryptocompare.com/api/#-api-data-price-
  :cryptocurrencies => {},

  # which modules are enabled, and in which order
  :module_order => [ :weather, :thermals, :cryptocurrencies, :keepalive,
    :network, :power, :audio, :date, :time ],
}

# override defaults by eval'ing ~/.dzen-jcs.rb
if File.exists?(f = "#{ENV['HOME']}/.dzen-jcs.rb")
  eval(File.read(f))
end

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

class Controller
  attr_reader :config
  attr_writer :dying

  MODULES = {
    :audio => {
      :i3status => :volume,
    },
    :cryptocurrencies => {
      :frequency => 60 * 5,
    },
    :date => {
      :frequency => 1,
    },
    :keepalive => {
      :frequency => 60,
    },
    :network => {
      :i3status => [ :ethernet, :wireless ],
    },
    :power => {
      :i3status => :battery,
    },
    :thermals => {
      :i3status => :cpu_temperature,
    },
    :time => {
      :frequency => 1,
    },
    :weather => {
      :frequency => 60 * 10,
    },
  }

  def initialize(config)
    @config = config
    @data = {}
    @threads = {}

    @dzen = nil
    @dzen_output = ""
    @i3status = nil
    @i3status_data = {}

    @dying = false
    @refresh = true

    @mutex = Mutex.new
  end

  def color(col)
    config[:colors][col]
  end

  def clense(str)
    # escape dzen control chars
    str.to_s.gsub(/\^/, "\\^").gsub("\n", " ").gsub("\r", "")
  end

  def run!
    if !File.exists?("/usr/local/bin/i3status")
      STDERR.puts "i3status not found"
      exit 1
    end

    # try to take dzen2 and i3status down with us
    [ "QUIT", "TERM", "INT" ].each do |sig|
      Kernel.trap(sig) do
        @dying = true
      end
    end

    # signal to toggle keep alive
    Kernel.trap("USR1") do
      MODULES[:keepalive][:toggle] = true
      @threads[:keepalive].wakeup
    end

    Thread.abort_on_exception = true

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

    # send data to dzen and handle blinking
    @threads[:dzen] = Thread.new do
      while @dzen
        break if @dying

        output = @dzen_output.dup

        if output.match(/\^blink\(/)
          output, dark = unblink(output)

          # flash output, darken it for a brief moment, then show it again
          @dzen.puts output
          sleep config[:blink].first
          @dzen.puts dark
          sleep config[:blink].last
          @dzen.puts output
        else
          @dzen.puts output
        end

        Thread.stop
      end

      cleanup_and_exit
    end

    # same for i3status
    @i3status = IO.popen("/usr/local/bin/i3status", "r+")

    # cache new data, then wakeup any threads that are sleeping waiting for
    # that data
    @threads[:i3status] = Thread.new do
      while @i3status && !@i3status.eof?
        break if @dying

        # [{"name":"wireless","instance":"iwn0","full_text":"up|166 dBm"},...
        next if !(m = @i3status.gets.to_s.match(/^,?(\[\{.*)/))

        new_data = {}
        JSON.parse(m[1]).each do |mod|
          new_data[mod["name"].to_sym] = mod
        end

        mod_updates = []
        (new_data.keys + @i3status_data.keys).uniq.each do |k,v|
          if @i3status_data[k] != new_data[k]
            # find any modules that are listening for this i3status data
            MODULES.each do |mod,modp|
              next if !modp[:i3status]

              if modp[:i3status].is_a?(Array)
                if modp[:i3status].include?(k)
                  mod_updates.push mod
                end
              elsif modp[:i3status] == k
                mod_updates.push mod
              end
            end
          end
        end

        @i3status_data = new_data

        mod_updates.uniq.each do |mod|
          if @threads[mod]
            @threads[mod].wakeup
          end
        end
      end

      cleanup_and_exit
    end

    # if either child dies, take us down
    [ :dzen, :i3status ].each do |child|
      @threads[:"#{child}_watcher"] = Thread.new do
        Process.waitpid(self.instance_variable_get("@#{child}").pid)
        STDERR.puts "#{child} exited #{$?.exitstatus}"
        cleanup_and_exit
      end
    end

    # spin up threads for each module
    config[:module_order].each do |mod|
      @threads[mod] = Thread.new do
        while true
          break if @dying

          begin
            ret = self.send(mod)

          rescue Timeout::Error
            ret = "^fg(#{color(:alert)})timeout error^fg()"
          rescue StandardError => e
            ret = "^fg(#{color(:alert)})error: #{e.class}^fg()"
            STDERR.puts e
            STDERR.puts e.backtrace.join("\n")
          end

          update_data(mod, ret)

          if MODULES[mod][:frequency]
            sleep MODULES[mod][:frequency]
          else
            Thread.stop
          end
        end
      end
    end

    # hang around as long as everything is running
    @threads.each do |k,v|
      v.join
    end

    cleanup_and_exit
  end

  # kill dzen2/i3status when we die
  def cleanup_and_exit
    if @dzen
      Process.kill(9, @dzen.pid)
    end

    if @i3status
      Process.kill(9, @i3status.pid)
    end

  rescue
  ensure
    exit
  end

  def update_data(mod, ret)
    @mutex.synchronize do
      if @data[mod] == ret
        return
      end

      @data[mod] = ret

      @dzen_output = config[:module_order].map{|m| @data[m] }.
        reject{|d| !d }.join(sep)
    end

    @threads[:dzen].wakeup
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

  # separator bar
  def sep
    "^fn(courier new:size=10)   ^fn(#{config[:font]})"
  end

  # data-collection routines

  # audio volume, or mute
  def audio
    return nil if !@i3status_data[:volume]

    o = "^fg()"

    if @i3status_data[:volume]["full_text"].match(/mute/)
      o << "^fg(#{color(:disabled)})"
    end

    o << "vol^fg(#{color(:disabled)})/"

    if @i3status_data[:volume]["full_text"].match(/mute/)
      o << "---"
    else
      vol = @i3status_data[:volume]["full_text"].gsub(/[^0-9]/, "").to_i

      if vol >= 75
        o << "^fg(#{color(:alert)})"
      else
        o << "^fg()"
      end

      o << "#{vol}^fg(#{color(:disabled)})%"
    end

    o << "^fg()"
  end

  # bluetooth interface status
  def bluetooth
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

  # prices of watched cryptocurrencies
  def cryptocurrencies
    return nil if !config[:cryptocurrencies].any?

    sd = Net::HTTP.get(URI.parse("https://min-api.cryptocompare.com/" +
      "data/pricemulti?fsyms=#{config[:cryptocurrencies].keys.join(",")}" +
      "&tsyms=USD"))

    js = JSON.parse(sd)
    # => {"ETH"=>{"USD"=>916.69}, "BTC"=>{"USD"=>14904.82}}

    out = []
    js.each do |cur,usd|
      c = config[:cryptocurrencies][cur.upcase.to_sym]
      if !c
        next
      end

      curlabel = case cur.downcase
      when "btc"
        "^fn(courier new:size=13)^fg(#ccc)\u0243^fg()^fn(#{config[:font]})"
      when "eth"
        "^fn(courier new:size=13)^fg(#ccc)\u039E^fg()^fn(#{config[:font]})"
      else
        cur.downcase
      end

      t = "#{curlabel} $#{usd["USD"].floor}"

      if c[:qty]
        quote = usd["USD"] * c[:qty].to_f

        if c[:cost]
          change = quote - c[:cost]

          color = ""
          if change == 0.0
            color = ""
            change = "=$#{change.floor}"
          elsif change > 0.0
            color = color(:ok)
            change = "+$#{change.floor}"
          elsif change < 0.0
            color = color(:emerg)
            change = "-$#{change.abs.ceil}"
          end

          t << " ^fg(#{color})#{change}^fg()"
        else
          t << " =$#{quote.floor}"
        end
      end

      out.push t
    end

    out.join(" ")
  end

  def date
    Time.now.strftime("%a %b %-d").downcase
  end

  def keepalive
    @keepalive ||= false

    if MODULES[:keepalive][:toggle]
      @keepalive = !@keepalive
      MODULES[:keepalive][:toggle] = false
    end

    if @keepalive
      system("xdotool mousemove_relative 1 1; " <<
        "xdotool mousemove_relative -- -1 -1")
    end

    # brightness emoji
    "^ca(1,pkill -USR1 -f #{File.basename($0)})" <<
      "^fn(noto emoji:size=13)^fg(#{@keepalive ? "" : color(:disabled)})" <<
      "\u{1F506}^fg()^fn(#{config[:font]})" <<
      "^ca()"
  end

  # wireless interface state and signal quality, ethernet interface status
  def network
    wifi_up = false
    wifi_connected = false
    wifi_signal = 0
    eth_connected = false

    if @i3status_data[:wireless] &&
    (m = @i3status_data[:wireless]["full_text"].to_s.match(/^up\|(.+)$/))
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

    if @i3status_data[:ethernet] &&
    @i3status_data[:ethernet]["full_text"].to_s.match(/up/)
      eth_connected = true
    end

    wi = ""
    eth = ""

    if wifi_up
      wi = "^ca(1,sh -c 'sudo ifconfig " <<
        "#{@i3status_data[:wireless]["instance"]} scan >/dev/null')"

      if wifi_connected && wifi_signal > 0
        if wifi_signal >= 60
          wi << "^fg()"
        elsif wifi_signal >= 45
          wi << "^fg(#{color(:alert)})"
        else
          wi << "^fg(#{color(:warn)})"
        end

        wi << "wifi^fg()"
      elsif wifi_connected
        wi << "^fg()wifi"
      elsif wifi_up
        wi << "^fg(#{color(:disabled)})wifi^fg()"
      end

      wi << "^ca()"
    end

    if eth_connected
      eth = "^fg()eth"
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

  # ac status, then each battery's percentage of power left
  def power
    return nil if !@i3status_data[:battery]

    batt_max = batt_left = batt_perc = {}, {}, {}
    ac_on = false
    run_rate = 0.0

    @i3status_data[:battery]["full_text"].split("|").each_with_index do |d,x|
      case x
      when 0
        ac_on = (d == "CHR")
      when 1
        batt_perc = { 0 => d.to_i }
      when 2
        run_rate = d.to_f
      end
    end

    out = "^fg(#{ac_on ? "" : color(:disabled)})ac"

    total_perc = batt_perc.values.inject{|a,b| a + b }

    batt_perc.keys.each do |i|
      out << "^fg(#{color(:disabled)})/"

      blink = false
      if batt_perc[i] <= 10.0
        out << "^fg(#{color(:emerg)})"
        if total_perc < 10.0 && !ac_on
          blink = true
        end
      elsif batt_perc[i] < 30.0
        out << "^fg(#{color(:alert)})"
      else
        out << "^fg()"
      end

      out << (blink ? "^blink(" : "") + batt_perc[i].to_s +
        (blink ? ")" : "") + "^fg(#{color(:disabled)})%^fg()"
    end

    if !batt_perc.any?
      out << "^fg(#{color(:disabled)})/?^fg()"
    end

    if run_rate > 0.0 && !ac_on
      out << "^fg(#{color(:disabled)})/^fg()"

      if run_rate >= 20.0
        out << "^fg(#{color(:emerg)})"
      elsif run_rate >= 10.0
        out << "^fg(#{color(:alert)})"
      end

      out << "#{sprintf("%0.1f", run_rate)}w^fg()"
    end

    out
  end

  # any temperature sensors that are too hot
  def thermals
    return nil if !@i3status_data[:cpu_temperature]

    temps = [
      @i3status_data[:cpu_temperature]["full_text"].to_f
    ]

    m = 0.0
    temps.each{|t| m += t }
    fh = (9.0 / 5.0) * (m / temps.length.to_f) + 32.0

    if fh > config[:temp_min]
      "^fg(#{color(:alert)})^blink(#{fh.to_i})^fg(#{color(:disabled)})f^fg()"
    else
      nil
    end
  end

  def time
    t = Time.now
    "^fg()" << t.strftime("%H") << "^fg(#{color(:disabled)}):^fg()" <<
      t.strftime("%M")
  end

  # current temperature/humidity
  def weather
    return nil if !config[:weather_api_key].any?

    if !config[:weather_lat_long].any?
      js = JSON.parse(Net::HTTP.get(URI.parse("http://ip-api.com/json")))
      if js["lat"] && js["lon"]
        config[:weather_lat_long] = "#{js["lat"]},#{js["lon"]}"
      end
    end

    return nil if !config[:weather_lat_long].any?

    js = JSON.parse(Net::HTTP.get(URI.parse(
      "https://api.darksky.net/forecast/" + config[:weather_api_key] +
      "/" + config[:weather_lat_long])))

    w = js["currently"]["summary"].downcase

    # add current temperature
    w << " ^fg()" << js["currently"]["apparentTemperature"].to_i.to_s <<
      "^fg(#{color(:disabled)})f^fg()"

    # add current humidity
    humidity = js["currently"]["humidity"].to_f * 100.0
    w << "^fg(#{color(:disabled)})/^fg(" <<
      (humidity > 60 ? color(:alert) : "") <<
      ")" << humidity.to_i.to_s << "^fg(#{color(:disabled)})%^fg()"

    w
  end
end

# on with the show
Controller.new(config).run!
