require 'httparty'
require 'pry'
require 'pry-nav'
require 'distribution'
require 'date'
require 'json'
require 'csv'
require 'nokogiri'
require 'net/smtp'

Dir["./handlers/*.rb"].each {|file| require file }

def et_today = Time.now.utc.then { |t| (t - 4 * 3600).to_date }

LEAGUE_AVG_ERA      = 4.20
LEAGUE_AVG_HARD_HIT = 0.35   # ~35% hard hit rate is MLB average
LEAGUE_AVG_BARREL   = 0.078  # ~7.8% barrel rate is MLB average
LEAGUE_AVG_WHIFF    = 0.245  # ~24.5% whiff rate is MLB average
LEAGUE_AVG_XWOBA    = 0.315  # ~.315 xwOBA is MLB average
WALK_RUN_VALUE      = 0.33   # linear-weight run expectancy of a walk
GMAIL_ADDRESS = 'marky.rigas@gmail.com'.freeze
EMAIL_RECIPIENTS = [GMAIL_ADDRESS].freeze
RUN_TOKEN = ENV.fetch('RUN_TOKEN', nil)

FunctionsFramework.http "main" do |request|
  return [200, {}, ["OK"]] if request.request_method == "HEAD"
  return [200, {}, ["OK"]] if request.path == "/health"

  if RUN_TOKEN && request.params['token'] != RUN_TOKEN
    return [403, {}, ["Forbidden"]]
  end

  return evaluate_model if request.params['action'] == 'evaluate'

  handler_class = request.params['handler'] ?
    Object.const_get("#{request.params['handler']&.split('_')&.collect(&:capitalize)&.join}Handler") :
    FantasyDataHandler

  Thread.new do
    email_buf = []
    tee = ->(line) { puts line; email_buf << line.gsub(/\e\[[0-9;]*m/, '') }

    begin
      [et_today].each do |date|
        handler = handler_class.new(date)
        puts "Using #{handler.class} for #{date}"

        proposals = []

        handler.stats.each do |s|
          next unless s[:home_pitcher][:era] && s[:away_pitcher][:era]

          # Pre-create RNG procs once per game — avoids 5000x object allocations
          rngs = {
            home_era: Distribution::Normal.rng(s[:home_pitcher][:era]),
            away_era: Distribution::Normal.rng(s[:away_pitcher][:era]),
            batter:   Distribution::Poisson.rng(FantasyDataHandler::LEAGUE_AVG_RBI_PER_GAME)
          }

          puts "  Simulating #{s[:away_team]} @ #{s[:home_team]}..."
          res = []
          5000.times { res << simulate_match(s, rngs).merge(s) }
          puts "  Done. Extracting proposals..."
          win_results = res.select { |x| x[:home] != x[:away] }
          a = handler.extract_proposals(res, win_results)
          proposals << a if a
        end

    tee.call("\n#{"═" * 52}")
    tee.call("  MLB BET PROPOSALS — #{date.strftime("%b %d, %Y")}")
    tee.call("#{"═" * 52}\n")

    proposals.each do |x|
      next if x[:home_pitcher][:era_warning] || x[:away_pitcher][:era_warning]

      [[x[:home_team], x[:home], x[:away]], [x[:away_team], x[:away], x[:home]]].each do |team, poss, opp_poss|
        next unless poss > 70

        is_home     = team == x[:home_team]
        pitcher     = is_home ? x[:home_pitcher][:name] : x[:away_pitcher][:name]
        opp_pitcher = is_home ? x[:away_pitcher][:name] : x[:home_pitcher][:name]
        color       = poss > 85 ? "\e[32m" : "\e[33m"
        bar         = ("█" * (poss / 10).round).ljust(10)

        matchup = "#{x[:away_team]} @ #{x[:home_team]}"
        tee.call("#{color}┌#{"─" * 50}┐")
        tee.call("│  %-48s│" % matchup)
        tee.call("│  %-48s│" % "#{team.upcase}  |  #{pitcher} vs #{opp_pitcher}")
        tee.call("│  Win:  #{bar}  #{poss.round(1).to_s.rjust(5)}%#{" " * 23}│")
        tee.call("│  Runs: O7.5 #{x[:o75].round(1).to_s.rjust(5)}%  O8.5 #{x[:o85].round(1).to_s.rjust(5)}%  O9.5 #{x[:o95].round(1).to_s.rjust(5)}%#{" " * 4}│")
        tee.call("│  Both scored: %-34s│" % "#{x[:both_scored].round(1)}%")
        tee.call("│  Avg total runs: %-31s│" % "#{x[:avg_total_runs].round(2)}  (#{x[:most_possible_runs_home]}-#{x[:most_possible_runs_away]} most likely)")
        tee.call("└#{"─" * 50}┘\n")
      end
    end

        handler.export_to_csv(proposals)
      end

      send_proposals_email(email_buf.join("\n")) unless email_buf.empty?
    rescue => e
      puts "Background run failed: #{e.class} — #{e.message}"
      puts e.backtrace.first(10).join("\n")
    end
  end

  [200, {}, ["Processing started — results will be emailed to #{EMAIL_RECIPIENTS.join(', ')}"]]
end

def simulate_match(match, rngs)
  expected_home_era = rngs[:home_era].call
  expected_away_era = rngs[:away_era].call

  away_barrel = match[:away_pitcher][:barrel_pct].then { |v| v&.positive? ? v : LEAGUE_AVG_BARREL }
  home_barrel = match[:home_pitcher][:barrel_pct].then { |v| v&.positive? ? v : LEAGUE_AVG_BARREL }
  away_xwoba  = match[:away_pitcher][:xwoba].then      { |v| v&.positive? ? v : LEAGUE_AVG_XWOBA }
  home_xwoba  = match[:home_pitcher][:xwoba].then      { |v| v&.positive? ? v : LEAGUE_AVG_XWOBA }

  away_blended_era = expected_away_era * 0.6 + (away_xwoba / LEAGUE_AVG_XWOBA) * LEAGUE_AVG_ERA * 0.4
  home_blended_era = expected_home_era * 0.6 + (home_xwoba / LEAGUE_AVG_XWOBA) * LEAGUE_AVG_ERA * 0.4

  away_era_scale = (away_blended_era / LEAGUE_AVG_ERA) * (1 + (away_barrel - LEAGUE_AVG_BARREL) * 2)
  home_era_scale = (home_blended_era / LEAGUE_AVG_ERA) * (1 + (home_barrel - LEAGUE_AVG_BARREL) * 2)

  home_runs = match[:home_avg_rbi].sum { rngs[:batter].call }
  away_runs = match[:away_avg_rbi].sum { rngs[:batter].call }

  {
    home_team:    match[:home_team],
    away_team:    match[:away_team],
    home:         [home_runs * away_era_scale, 0].max,
    away:         [away_runs * home_era_scale, 0].max,
    home_pitcher: match[:home_pitcher][:name],
    away_pitcher: match[:away_pitcher][:name]
  }
end

def evaluate_model
  files = Dir.glob('proposals/*.csv').sort.reject do |f|
    File.basename(f, '.csv') == Date.today.strftime('%Y-%m-%d')
  end

  return "No archived proposals found. Run the predictor first to build history.\n" if files.empty?

  stats = Hash.new { |h, k| h[k] = { correct: 0, total: 0 } }
  skipped = 0

  files.each do |file|
    date = File.basename(file, '.csv')
    response = HTTParty.get(
      'https://statsapi.mlb.com/api/v1/schedule',
      query: { sportId: 1, date: date, hydrate: 'linescore' }
    )
    next unless response.success?

    final_games = (response.parsed_response.dig('dates', 0, 'games') || [])
      .select { |g| g.dig('status', 'detailedState') == 'Final' }

    CSV.foreach(file, headers: true, col_sep: ';') do |row|
      home_team    = row['home_team']
      away_team    = row['away_team']
      home_pitcher = row['home_pitcher']
      away_pitcher = row['away_pitcher']
      home_pct     = row['home_pct'].to_f
      away_pct     = row['away_pct'].to_f

      matching = final_games.select { |g|
        teams_match?(g.dig('teams', 'home', 'team', 'name'), home_team) &&
        teams_match?(g.dig('teams', 'away', 'team', 'name'), away_team)
      }

      if matching.empty?
        skipped += 1
        next
      end

      game = matching.size == 1 ? matching.first : find_game_by_pitcher(matching, home_pitcher, away_pitcher)

      if game.nil?
        skipped += 1
        next
      end

      actual_home  = game.dig('teams', 'home', 'score').to_i
      actual_away  = game.dig('teams', 'away', 'score').to_i
      actual_total = actual_home + actual_away
      home_won     = actual_home > actual_away

      predicted_home_wins = home_pct > away_pct
      stats[:win][:correct] += 1 if predicted_home_wins == home_won
      stats[:win][:total]   += 1

      if home_pct > 70 || away_pct > 70
        stats[:win_confident][:correct] += 1 if predicted_home_wins == home_won
        stats[:win_confident][:total]   += 1
      end

      { o75: 7.5, o85: 8.5, o95: 9.5 }.each do |key, threshold|
        stats[key][:correct] += 1 if actual_total > threshold
        stats[key][:total]   += 1
      end

      stats[:both][:correct] += 1 if actual_home > 0 && actual_away > 0
      stats[:both][:total]   += 1
    end
  end

  labels = {
    win:           'Win (all)        ',
    win_confident: 'Win (>70% only)  ',
    o75:           'Over 7.5 runs    ',
    o85:           'Over 8.5 runs    ',
    o95:           'Over 9.5 runs    ',
    both:          'Both scored      '
  }

  lines = []
  lines << "#{'═' * 44}"
  lines << '  MODEL ACCURACY REPORT'
  lines << "  #{files.size} date(s) evaluated  |  #{skipped} unmatched"
  lines << "#{'═' * 44}"
  lines << ''
  labels.each do |key, label|
    s = stats[key]
    if s[:total] > 0
      pct = (s[:correct] / s[:total].to_f * 100).round(1)
      lines << "#{label}  #{s[:correct]}/#{s[:total]}  (#{pct}%)"
    else
      lines << "#{label}  N/A"
    end
  end
  lines << ''
  lines.join("\n")
end

def teams_match?(api_name, csv_name)
  return false unless api_name && csv_name
  api_name.downcase.include?(csv_name.downcase)
end

def find_game_by_pitcher(games, home_pitcher, away_pitcher)
  home_last = home_pitcher.to_s.split.last&.downcase
  away_last = away_pitcher.to_s.split.last&.downcase

  games.each do |game|
    boxscore = HTTParty.get("https://statsapi.mlb.com/api/v1/game/#{game['gamePk']}/boxscore")
    next unless boxscore.success?

    home_id      = boxscore.parsed_response.dig('teams', 'home', 'pitchers', 0)
    away_id      = boxscore.parsed_response.dig('teams', 'away', 'pitchers', 0)
    home_starter = boxscore.parsed_response.dig('teams', 'home', 'players', "ID#{home_id}", 'person', 'fullName').to_s
    away_starter = boxscore.parsed_response.dig('teams', 'away', 'players', "ID#{away_id}", 'person', 'fullName').to_s

    return game if home_starter.downcase.include?(home_last.to_s) &&
                   away_starter.downcase.include?(away_last.to_s)
  end

  nil
end

def send_proposals_email(body)
  password = ENV['GMAIL_APP_PASSWORD']
  unless password
    puts "GMAIL_APP_PASSWORD env var not set — skipping email"
    return
  end

  date_str = et_today.strftime('%Y-%m-%d')
  message = <<~MSG
    From: MLB Predictor <#{GMAIL_ADDRESS}>
    To: #{EMAIL_RECIPIENTS.join(', ')}
    Subject: Bet proposals #{date_str}
    Content-Type: text/plain; charset=UTF-8

    #{body}
  MSG

  smtp = Net::SMTP.new('smtp.gmail.com', 587)
  smtp.enable_starttls
  smtp.start('localhost', GMAIL_ADDRESS, password, :login) do |s|
    s.send_message(message, GMAIL_ADDRESS, EMAIL_RECIPIENTS)
  end
  puts "Email sent to #{EMAIL_RECIPIENTS.join(', ')}"
rescue => e
  puts "Email failed: #{e.message}"
end

