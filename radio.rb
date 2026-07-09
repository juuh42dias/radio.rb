#!/usr/bin/env ruby
# frozen_string_literal: true

# Terminal Radio Player — ASCII-enhanced
# Controls: [space]=Play/Pause  n=Next  p=Prev  +=VolUp  -=VolDown
#           s=Select  a=Add  r=Remove  l=List  A=Autoplay  R=Defaults  q=Quit
# Persisted stations: ~/.terminal_radio/stations.yml
# Requires external player: mpg123 (brew install mpg123 / apt-get install mpg123)
# Optional gems: artii, pastel, tty-box, tty-spinner (see Gemfile)

begin
  require 'bundler/setup'
rescue LoadError
end

begin
  require 'artii'
  require 'pastel'
  require 'tty-box'
  require 'tty-spinner'
rescue LoadError
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
  { name: 'Radio Swiss Jazz (MP3 128k)', url: 'http://stream.srg-ssr.ch/m/rsj/mp3_128' },
  { name: 'Playback FM', url: 'https://listen.radionomy.com/playbackfm' },
  { name: 'K-Rose', url: 'https://listen.radionomy.com/k-rose' },
  { name: 'K-DST', url: 'https://listen.radionomy.com/k-dst' },
  { name: 'Bounce FM', url: 'https://listen.radionomy.com/bounce-fm' },
  { name: 'SF-UR', url: 'https://listen.radionomy.com/sf-ur' },
  { name: 'Radio Los Santos', url: 'https://listen.radionomy.com/radio-los-santos' },
  { name: 'Radio X', url: 'https://listen.radionomy.com/radio-x' },
  { name: 'CSR 103.9', url: 'https://listen.radionomy.com/csr-103-9' },
  { name: 'Master Sounds 98.3', url: 'https://listen.radionomy.com/master-sounds-98-3' },
  { name: 'WCTR Talk Radio', url: 'https://listen.radionomy.com/wctr-talk-radio' }
]

# UX helpers
module UX
  def self.artii(text)
    return text unless defined?(Artii)
    Artii::Base.new(asciify: true).asciify(text)
  rescue
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
    defined?(TTY::Spinner) ? TTY::Spinner.new("[:spinner] #{message}", format: :pulse) : nil
  end
end

# Station persistence with defaults merged
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
    saved = YAML.safe_load(File.read(@path), permitted_classes: [Symbol]) || []
    merge_with_defaults(saved)
  rescue
    DEFAULT_STATIONS
  end

  def add(name, url)
    list = all
    list << { 'name' => name, 'url' => url }
    save(list)
  end

  def save(list)
    File.write(@path, list.to_yaml)
  end

  def restore_defaults
    save(DEFAULT_STATIONS.map { |s| { 'name' => s[:name], 'url' => s[:url] } })
  end

  private

  def merge_with_defaults(saved)
    names = saved.map { |s| s['name'] }
    merged = saved.dup
    DEFAULT_STATIONS.each do |d|
      next if names.include?(d[:name])
      merged << { 'name' => d[:name], 'url' => d[:url] }
    end
    merged
  end
end

# mpg123 remote control wrapper
class Mpg123Remote
  def initialize
    abort 'mpg123 not found. Please install it first.' unless which('mpg123')
  end

  def start
    @proc_in, @proc_out, @wait_thr = Open3.popen2('mpg123', '-R')
    Thread.new do
      while (line = @proc_out.gets)
        break if line.strip.empty?
      end
    rescue IOError
    end
  end

  def load(url)  = send_cmd("LOAD #{url}")
  def pause      = send_cmd('PAUSE')
  def stop       = send_cmd('STOP')
  def volume(p)  = send_cmd("VOLUME #{[[p,0].max,100].min}")
  def quit
    send_cmd('QUIT')
    @proc_in.close unless @proc_in.closed?
    @proc_out.close unless @proc_out.closed?
    @wait_thr.value if @wait_thr
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
    @player.quit rescue nil
    puts "\nBye! 👋"
  end

  private

  def normalize(list)
    list.map { |s| { 'name' => s['name'] || s[:name], 'url' => s['url'] || s[:url] } }
  end

  def clear = print "\e[2J\e[H"

  def status_line
    cur = @stations[@index]
    name = cur ? cur['name'] : '—'
    now = @now_playing ? " | #{@now_playing}" : ''
    vol = "Vol: #{@volume}%"
    base = "#{@index + 1}/#{@stations.size}: #{name}#{now}  | #{vol}"
    @pastel ? @pastel.decorate(base, :bold) : base
  end

  def redraw_status
    width = IO.console.winsize[1] rescue 120
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

  def toggle_pause = @player.pause
  def next_station = (@index = (@index + 1) % @stations.size; play_current)
  def prev_station = (@index = (@index - 1) % @stations.size; play_current)

  def set_volume(v)
    @volume = [[v, 0].max, 100].min
    @player.volume(@volume)
    redraw_status
  end

  def pick_station
    puts "\n"
    content = @stations.each_with_index.map { |s, i| "#{i == @index ? '*' : ' '} #{i + 1}. #{s['name']}" }.join("\n")
    puts UX.box(content)
    print "\nNumber (or blank to cancel): "
    choice = STDIN.gets&.strip
    return if choice.nil? || choice.empty?
    num = choice.to_i
    if num.between?(1, @stations.size)
      @index = num - 1
      play_current
    else
      puts 'Invalid choice.'
    end
  end

  def add_station
    print "\nStation name: "; name = STDIN.gets&.strip
    return if name.nil? || name.empty?
    print 'Stream URL: '; url = STDIN.gets&.strip
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
    width = IO.console.winsize[1] rescue 80
    puts UX.box(content, width: width)
    puts "----------------\n"
  end

  def play_all
    Thread.new do
      loop do
        play_current
        sleep 60
        next_station
      end
    end
  end

  def restore_defaults
    confirm = nil
    print "\nThis will reset your stations to defaults. Continue? (y/N): "
    confirm = STDIN.gets&.strip&.downcase
    return unless confirm == 'y'

    @store.restore_defaults
    @stations = normalize(@store.all)
    @index = 0
    play_current
    puts "Defaults restored."
  end

  def input_loop
    STDIN.raw do
      loop do
        redraw_status
        ch = STDIN.getch
        case ch
        when 'q', "\u0003" then break
        when ' ', 'k'       then toggle_pause
        when 'n', "\e[C"    then next_station
        when 'p', "\e[D"    then prev_station
        when '+', '='       then set_volume(@volume + 5)
        when '-', '_'       then set_volume(@volume - 5)
        when 's'            then print "\n"; pick_station
        when 'a'            then add_station
        when 'r'            then remove_station
        when 'l'            then list_stations
        when 'A'            then puts "\nAutoplaying all stations..."; play_all
        when 'R'            then restore_defaults
        end
      end
    end
  end

  def print_banner
    puts defined?(Artii) ? UX.artii('Terminal Radio') : '*** Terminal Radio ***'
    puts UX.box(
      'Controls: [space]=Play/Pause  n=Next  p=Prev  +=VolUp  -=VolDown  ' \
      's=Select  a=Add  r=Remove  l=List  A=Autoplay  R=RestoreDefaults  q=Quit'
    )
    puts
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
