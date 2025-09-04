#!/usr/bin/env ruby
# frozen_string_literal: true

# Terminal Radio Player — ASCII-enhanced
# Controls: [space]=Play/Pause, n=Next, p=Prev, +=Vol+, -=Vol-, a=Add station, s=Pick station, r=Remove, l=List, q=Quit
# Persisted stations: ~/.terminal_radio/stations.yml
# Requires external player: mpg123 (install with brew/apt/pacman/dnf)
# Use bundler (optional) to install suggested gems in Gemfile.

begin
  require 'bundler/setup'
rescue LoadError
  # bundler not required; continue
end

# Optional/UX gems — graceful fallback if not installed
begin
  require 'artii'      # ASCII fonts
  require 'pastel'     # colors
  require 'tty-box'    # boxed sections
  require 'tty-spinner' # spinner while loading
rescue LoadError
  # We'll continue without those niceties if they aren't available
end

require 'io/console'
require 'yaml'
require 'fileutils'
require 'open3'

APP_DIR = File.join(Dir.home, '.terminal_radio')
STATIONS_FILE = File.join(APP_DIR, 'stations.yml')

DEFAULT_STATIONS = [
  { name: 'SomaFM - Groove Salad', url: 'https://ice2.somafm.com/groovesalad-128-mp3' },
  { name: 'SomaFM - Illinois Street Lounge', url: 'https://ice6.somafm.com/illstreet-128-mp3' },
  { name: 'Radio Paradise (Main MP3 192k)', url: 'https://stream.radioparadise.com/mp3-192' },
  { name: 'Radio Swiss Jazz (MP3 128k)', url: 'http://stream.srg-ssr.ch/m/rsj/mp3_128' }
]

# Helpers for optional UX
module UX
  def self.artii(text)
    return text unless defined?(Artii)

    Artii::Base.new(asciify: true).asciify(text)
  rescue StandardError
    text
  end

  def self.pastel
    defined?(Pastel) ? Pastel.new : nil
  end

  def self.box(content, **opts)
    if defined?(TTY::Box)
      TTY::Box.frame(width: opts[:width] || 60, padding: 1) { content }
    else
      content
    end
  end

  def self.spinner(message)
    return unless defined?(TTY::Spinner)

    TTY::Spinner.new("[:spinner] #{message}", format: :pulse)
  end
end

class StationStore
  def initialize(path)
    @path = path
    FileUtils.mkdir_p(File.dirname(@path))
    seed unless File.exist?(@path)
  end

  def seed
    File.write(@path, DEFAULT_STATIONS.to_yaml)
  end

  def all
    YAML.safe_load(File.read(@path), permitted_classes: [Symbol]) || []
  rescue StandardError
    []
  end

  def add(name, url)
    list = all
    list << { 'name' => name, 'url' => url }
    File.write(@path, list.to_yaml)
  end

  def save(list)
    File.write(@path, list.to_yaml)
  end
end

class Mpg123Remote
  attr_reader :proc_in, :proc_out

  def initialize
    return if which('mpg123')

    abort 'mpg123 not found. Please install it first (e.g., brew install mpg123 or apt-get install mpg123).'
  end

  def start
    @proc_in, @proc_out, @wait_thr = Open3.popen2('mpg123', '-R')
    # drain initial banner (from stdout)
    Thread.new do
      while (line = @proc_out.gets)
        break if line.strip.empty?
      end
    rescue IOError
    end
  end

  def load(url)
    send_cmd("LOAD #{url}")
  end

  def pause
    send_cmd('PAUSE')
  end

  def stop
    send_cmd('STOP')
  end

  def quit
    send_cmd('QUIT')
    @proc_in.close unless @proc_in.closed?
    @proc_out.close unless @proc_out.closed?
    @wait_thr.value if @wait_thr
  end

  def volume(percent)
    percent = [[percent, 0].max, 100].min
    send_cmd("VOLUME #{percent}")
  end

  def on_lines(&block)
    @reader = Thread.new do
      while (line = @proc_out.gets)
        block.call(line)
      end
    rescue IOError
    end
  end

  def stop_reader
    @reader&.kill
  end

  private

  def send_cmd(cmd)
    @proc_in.puts(cmd)
    @proc_in.flush
  rescue Errno::EPIPE
    # player died
  end

  def which(cmd)
    exts = ENV['PATHEXT'] ? ENV['PATHEXT'].split(';') : ['']
    ENV['PATH'].split(File::PATH_SEPARATOR).each do |path|
      exts.each do |ext|
        exe = File.join(path, "#{cmd}#{ext}")
        return exe if File.exist?(exe) && File.executable?(exe)
      end
    end
    nil
  end
end

class TerminalRadio
  def initialize
    @store = StationStore.new(STATIONS_FILE)
    @stations = normalize(@store.all)
    @index = 0
    @volume = 80
    @player = Mpg123Remote.new
    @now_playing = nil
    @pastel = UX.pastel
  end

  def run
    clear
    print_banner
    @player.start
    @player.on_lines { |line| handle_player_line(line) }
    set_volume(@volume)
    play_current

    input_loop
  ensure
    @player.stop_reader
    begin
      @player.quit
    rescue StandardError
      nil
    end
    puts "\nBye! 👋"
  end

  private

  def normalize(list)
    list.map do |s|
      {
        'name' => s['name'] || s[:name],
        'url' => s['url'] || s[:url]
      }
    end
  end

  def print_banner
    header = if defined?(Artii)
               UX.artii('Terminal Radio')
             else
               '*** Terminal Radio ***'
             end

    puts header
    puts UX.box('Controls: [space]=Play/Pause  n=Next  p=Prev  +=VolUp  -=VolDown  s=Select  a=Add  r=Remove  l=List  q=Quit')
    puts
  end

  def clear
    print "\e[2J\e[H"
  end

  def status_line
    cur = @stations[@index]
    name = cur ? cur['name'] : '—'
    now = @now_playing ? " | #{@now_playing}" : ''
    vol = "Vol: #{@volume}%"
    base = "#{@index + 1}/#{@stations.size}: #{name}#{now}  | #{vol}"
    return base unless @pastel

    @pastel.decorate(base, :bold)
  end

  def redraw_status
    width = begin
      IO.console.winsize[1]
    rescue StandardError
      120
    end
    print "\r#{' ' * width}\r"
    print status_line
    $stdout.flush
  end

  def play_current
    url = @stations[@index]['url']
    spinner = UX.spinner("Connecting to #{url}")
    spinner&.auto_spin
    @player.load(url)
    sleep 0.3
    spinner&.stop
    redraw_status
  end

  def toggle_pause
    @player.pause
  end

  def next_station
    @index = (@index + 1) % @stations.size
    play_current
  end

  def prev_station
    @index = (@index - 1) % @stations.size
    play_current
  end

  def set_volume(v)
    @volume = [[v, 0].max, 100].min
    @player.volume(@volume)
    redraw_status
  end

  def pick_station
    puts "\n"
    content = @stations.each_with_index.map do |s, i|
      marker = (i == @index ? '*' : ' ')
      "#{marker} #{i + 1}. #{s['name']}"
    end.join("\n")

    puts UX.box(content)
    print "\nNumber (or blank to cancel): "
    choice = STDIN.gets&.strip
    return if choice.nil? || choice.empty?

    num = choice.to_i
    if num >= 1 && num <= @stations.size
      @index = num - 1
      play_current
    else
      puts 'Invalid choice.'
    end
  end

  def add_station
    print "\nStation name: "
    name = STDIN.gets&.strip
    return if name.nil? || name.empty?

    print 'Stream URL (MP3/AAC recommended): '
    url = STDIN.gets&.strip
    return if url.nil? || url.empty?

    @store.add(name, url)
    @stations = normalize(@store.all)
    @index = @stations.size - 1
    play_current
    puts "Added '#{name}'."
  end

  def remove_station
    puts "\nEnter number to remove (1-#{@stations.size}):"
    n = STDIN.gets&.strip&.to_i
    return if n.nil? || n <= 0 || n > @stations.size

    removed = @stations.delete_at(n - 1)
    @store.save(@stations)
    @index = [[@index, @stations.size - 1].min, 0].max
    puts "Removed '#{removed['name']}'."
    play_current if @stations.any?
  end

  def list_stations
    puts "\n--- Stations ---"
    content = @stations.each_with_index.map do |s, i|
      marker = (i == @index ? '*' : ' ')
      "#{marker} #{i + 1}. #{s['name']} (#{s['url']})"
    end.join("\n")
    puts UX.box(content, width: begin
      IO.console.winsize[1]
    rescue StandardError
      80
    end)
    puts "----------------\n"
  end

  def input_loop
    STDIN.raw do
      loop do
        redraw_status
        ch = STDIN.getch
        case ch
        when 'q', "\u0003" # Ctrl-C
          break
        when ' ', 'k' # toggle pause
          toggle_pause
        when 'n', "\e[C" # right arrow
          next_station
        when 'p', "\e[D" # left arrow
          prev_station
        when '+', '='
          set_volume(@volume + 5)
        when '-', '_'
          set_volume(@volume - 5)
        when 's'
          print "\n"
          pick_station
        when 'a'
          add_station
        when 'r'
          remove_station
        when 'l'
          list_stations
        else
          # ignore
        end
      end
    end
  end

  def handle_player_line(line)
    if line.start_with?('@S')
      @now_playing = nil
    elsif line.start_with?('@I')
      if (m = line.match(/ICY-?(?:NAME|TITLE)=([^\r\n]+)/i))
        @now_playing = m[1].strip
      end
    end
    redraw_status
  end
end

TerminalRadio.new.run if __FILE__ == $0
