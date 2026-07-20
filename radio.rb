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
    @proc_in, @proc_out, @wait_thr = Open3.popen2('mpg123', '-R', err: File::NULL)
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
    @state = :stopped
    @elapsed = 0.0
    @total = nil
    @error = nil
    @tick = 0
    @notice = nil
    @header_height = 0
    @suspend_draw = false
    @draw_lock = Mutex.new
    @rendered_lines = nil
  end

  def run
    repaint
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

  PLAYER_MIN_WIDTH = 46
  PLAYER_MAX_WIDTH = 78
  PLAYER_FRAME_HEIGHT = 6

  CONTROLS = [
    ['space', 'play / pause'],
    ['n',     'next station'],
    ['p',     'previous station'],
    ['+ -',   'volume up / down'],
    ['s',     'select station'],
    ['l',     'list stations'],
    ['a',     'add station'],
    ['r',     'remove station'],
    ['A',     'autoplay all'],
    ['R',     'restore defaults'],
    ['q',     'quit']
  ].freeze

  def term_width
    IO.console.winsize[1]
  rescue StandardError
    80
  end

  def player_width
    [[term_width - 2, PLAYER_MIN_WIDTH].max, PLAYER_MAX_WIDTH].min
  end

  def paint(text, *styles)
    return text if @pastel.nil? || styles.empty?

    @pastel.decorate(text, *styles)
  end

  def truncate(text, max)
    return '' if max <= 0

    text.length <= max ? text : "#{text[0, max - 1]}…"
  end

  def fmt_time(secs)
    return '--:--' if secs.nil? || secs.negative?

    hours, rest = secs.round.divmod(3600)
    mins, sec = rest.divmod(60)
    hours.positive? ? format('%d:%02d:%02d', hours, mins, sec) : format('%02d:%02d', mins, sec)
  end

  def box_top(title, width)
    paint("╭─ #{title} #{'─' * [width - title.length - 5, 0].max}╮", :bright_black)
  end

  def box_bottom(width)
    paint("╰#{'─' * (width - 2)}╯", :bright_black)
  end

  # A segment is [text, *styles] and gets painted here, or [:painted, text, width]
  # for text that is already coloured and must report its own visible width.
  # Padding always measures visible cells, so ANSI escapes can't skew the box.
  def frame_row(segments, inner)
    visible = segments.sum { |seg| seg[0] == :painted ? seg[2] : seg[0].length }
    body = segments.map { |seg| seg[0] == :painted ? seg[1] : paint(seg[0], *seg[1..]) }.join
    "│ #{body}#{' ' * [inner - visible, 0].max} │"
  end

  def state_icon
    case @state
    when :playing    then ['▸ ', :green]
    when :paused     then ['❚❚', :yellow]
    when :connecting then ['◌ ', :cyan]
    else                  ['▪ ', :red]
    end
  end

  def slider(width)
    return '' if width <= 0

    band = 6
    head = @tick % (width + band)
    Array.new(width) { |i| i >= head - band && i < head ? paint('━', :bright_cyan) : paint('─', :bright_black) }.join
  end

  def volume_meter
    filled = [[(@volume / 10.0).round, 0].max, 10].min
    paint('▰' * filled, :green) + paint('▱' * (10 - filled), :bright_black)
  end

  def status_subtitle
    return [@error, :red] if @error

    case @state
    when :connecting then ['connecting…', :bright_black]
    when :stopped    then ['stream stopped', :yellow]
    else [@now_playing || 'live stream', :bright_black]
    end
  end

  def player_frame
    width = player_width
    inner = width - 4
    icon, icon_style = state_icon
    station = @stations[@index]
    title = truncate(station ? station['name'] : '—', inner - 4)
    subtitle, subtitle_style = status_subtitle
    track = truncate(subtitle, inner - 4)
    clock = "LIVE"
    counter = "#{@index + 1}/#{@stations.size}"
    vol = "#{@volume}%".rjust(4)

    bar_width = inner - clock.length - 2
    # VOL(4) + meter(10) + space(1) + vol(4) + ♫(2) = 21 cells of fixed content
    gap = [inner - 21 - counter.length, 1].max

    [
      box_top('NOW PLAYING', width),
      frame_row([[icon, icon_style, :bold], ['  '], [title, :bold, :white]], inner),
      frame_row([['    '], [track, subtitle_style]], inner),
      frame_row([[:painted, slider(bar_width), bar_width], ['  '], [clock, :cyan]], inner),
      frame_row([['VOL '], [:painted, volume_meter, 10], [' '], [vol, :bright_black],
                 [' ' * gap], ['♫ ', :magenta], [counter, :bright_black]], inner),
      box_bottom(width)
    ]
  end

  def redraw_status
    @draw_lock.synchronize do
      next if @suspend_draw

      @tick += 1
      # The notice rides inside the redrawn block on purpose: \e[J wipes to the
      # end of the screen, so anything printed below the frame would be erased
      # on the next tick.
      lines = player_frame + notice_block
      print "\e[#{@rendered_lines}A\e[J" if @rendered_lines
      print lines.join("\r\n") + "\r\n"
      @rendered_lines = lines.size
      $stdout.flush
    end
  end

  def term_height
    IO.console.winsize[0]
  rescue StandardError
    24
  end

  # Trimmed to the rows left under the header and frame; a notice that wrapped
  # or overflowed would desync the cursor-up count and smear the redraw.
  def notice_block
    return [] if @notice.nil? || @notice.empty?

    budget = term_height - @header_height - PLAYER_FRAME_HEIGHT - 2
    return [] if budget < 2

    lines = @notice.lines.map { |l| clamp_line(l.chomp) }
    return ['', *lines] if lines.size <= budget - 1

    shown = budget - 2
    ['', *lines.first(shown), paint("… #{lines.size - shown} more", :bright_black)]
  end

  # Only unpainted lines are cut — slicing a coloured line could sever an escape.
  def clamp_line(line)
    max = term_width - 2
    return line if line.include?("\e") || line.length <= max

    "#{line[0, max - 1]}…"
  end

  def notify(message)
    @notice = message
    redraw_status
  end

  # Full repaint: clear, header, frame, notice. Used on startup and after any
  # command that scrolled the screen.
  def repaint
    @draw_lock.synchronize do
      clear
      print_header
      @rendered_lines = nil
    end
    redraw_status
  end

  # The reader thread redraws the frame several times a second, which would
  # bury any scrolling output. Hold it off, then repaint from a clean screen.
  # Audio is untouched — mpg123 keeps playing throughout.
  def without_player_draw
    @draw_lock.synchronize { @suspend_draw = true }
    yield
  ensure
    @draw_lock.synchronize { @suspend_draw = false }
    repaint
  end

  # Prompts also need cooked mode: input_loop keeps the terminal raw, where
  # Enter arrives as \r and STDIN.gets would block forever waiting for \n.
  # The header is reprinted first so the prompt appears under the usual chrome.
  def with_prompt(&block)
    without_player_draw do
      @draw_lock.synchronize { clear; print_header }
      STDIN.cooked(&block)
    end
  end

  # No external spinner here: it printed between frames and shifted the cursor,
  # so the next in-place redraw anchored one line low and stranded a duplicate
  # header. The connecting state lives inside the frame instead.
  def play_current
    @elapsed = 0.0
    @total = nil
    @now_playing = nil
    @error = nil
    @notice = nil
    @state = :connecting
    redraw_status
    @player.load(@stations[@index]['url'])
    sleep 0.3
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
    with_prompt do
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
        @notice = paint('Invalid choice.', :red)
      end
    end
  end

  def add_station
    with_prompt do
      print "\nStation name: "; name = STDIN.gets&.strip
      return if name.nil? || name.empty?
      print 'Stream URL: '; url = STDIN.gets&.strip
      return if url.nil? || url.empty?
      @store.add(name, url)
      @stations = normalize(@store.all)
      @index = @stations.size - 1
      play_current
      @notice = paint("Added '#{name}'.", :green)
    end
  end

  def remove_station
    with_prompt do
      puts "\nEnter number to remove (1-#{@stations.size}):"
      n = STDIN.gets&.strip&.to_i
      return if n.nil? || n <= 0 || n > @stations.size
      removed = @stations.delete_at(n - 1)
      @store.save(@stations)
      @index = [[@index, @stations.size - 1].min, 0].max
      play_current if @stations.any?
      @notice = paint("Removed '#{removed['name']}'.", :green)
    end
  end

  # Rendered as a notice under the player rather than scrolled, so the header
  # and frame stay put and the list survives the next redraw.
  def list_stations
    rows = @stations.each_with_index.map do |s, i|
      marker = i == @index ? paint('▸', :green) : ' '
      "#{marker} #{(i + 1).to_s.rjust(2)}. #{s['name']}"
    end
    notify(["#{paint('Stations', :bold)} (#{@stations.size})", *rows].join("\n"))
  end

  def play_all
    @notice = paint('Autoplaying all stations…', :cyan)
    Thread.new do
      loop do
        play_current
        sleep 60
        next_station
      end
    end
    # The keymap prints its own line before calling this; repaint clears it so
    # the stray text cannot desync the redraw anchor.
    repaint
  end

  def restore_defaults
    with_prompt do
      print "\nThis will reset your stations to defaults. Continue? (y/N): "
      confirm = STDIN.gets&.strip&.downcase
      return unless confirm == 'y'

      @store.restore_defaults
      @stations = normalize(@store.all)
      @index = 0
      play_current
      @notice = paint('Defaults restored.', :green)
    end
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

  def render_controls(width)
    inner = width - 4
    key_w = CONTROLS.map { |key, _| key.length }.max
    desc_w = CONTROLS.map { |_, desc| desc.length }.max
    cell_w = key_w + 2 + desc_w
    gutter = 2
    cols = [[(inner + gutter) / (cell_w + gutter), 1].max, CONTROLS.size].min
    rows = (CONTROLS.size.to_f / cols).ceil

    lines = [box_top('CONTROLS', width)]
    rows.times do |row|
      segments = []
      cols.times do |col|
        key, desc = CONTROLS[row * cols + col]
        next if key.nil?
        segments << [' ' * gutter] unless col.zero?
        segments << [key.rjust(key_w), :cyan, :bold]
        segments << ['  ']
        segments << [desc.ljust(desc_w), :bright_black]
      end
      lines << frame_row(segments, inner)
    end
    lines << box_bottom(width)
  end

  def print_header
    title = if defined?(Artii) && term_height >= 32
              UX.artii('Terminal Radio')
            else
              paint('♫ TERMINAL RADIO', :bold, :cyan)
            end
    lines = title.lines.map(&:chomp) + render_controls(player_width) + ['']
    @header_height = lines.size
    print lines.join("\r\n") + "\r\n"
    $stdout.flush
  end

  def handle_player_line(line)
    case line
    when /\A@F\s+\S+\s+\S+\s+(\S+)\s+(\S+)/
      @elapsed = Regexp.last_match(1).to_f
      remaining = Regexp.last_match(2).to_f
      @total = remaining.positive? ? @elapsed + remaining : nil
      # Frames only flow while audio is decoding, so they are proof of
      # playback. @P 2 is a single line and can be missed; @F keeps coming,
      # so the connecting state can never strand on one lost message.
      @state = :playing if @state == :connecting
      return if @last_tick && (Time.now - @last_tick) < 0.25
      @last_tick = Time.now
    when /\A@E\s+(.+)/
      @error = Regexp.last_match(1).strip
      @state = :stopped
    when /\A@P\s+(\d)/
      @state = { '0' => :stopped, '1' => :paused, '2' => :playing }.fetch(Regexp.last_match(1), :playing)
      @error = nil if @state == :playing
    when /\A@S/
      @now_playing = nil
      @state = :playing
    when /\A@I/
      if (m = line.match(/StreamTitle\s*=\s*'([^']*)'/i))
        title = m[1].strip
        @now_playing = title unless title.empty?
      elsif (m = line.match(/ICY-?NAME\s*[=:]\s*([^\r\n;]+)/i))
        @now_playing = m[1].strip
      end
    end
    redraw_status
  end
end

TerminalRadio.new.run if __FILE__ == $0
