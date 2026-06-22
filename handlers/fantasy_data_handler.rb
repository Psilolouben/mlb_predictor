require_relative './base_handler.rb'

class FantasyDataHandler < BaseHandler
  def data
    selenium_driver.navigate.to games_url
    wait = Selenium::WebDriver::Wait.new(timeout: 20)
    wait.until { selenium_driver.find_elements(css: '.lineup').length > 0 }
    Nokogiri::HTML(selenium_driver.page_source).xpath("//*[@class='lineup']")
  rescue Selenium::WebDriver::Error::TimeoutError
    puts "Timed out waiting for lineups on #{games_url}"
    []
  end

  def lineups
    data.map do |m|
      home_players = m.children[3].children.map do |c|
        next if c.children.empty?
        c.children[3].nil? ? nil : c.children[3].attributes['href'].value.split('/').last
      end.compact
      home_players.delete_at(0)

      away_players = m.children[1].children.map do |c|
        next if c.children.empty?
        c.children[3].nil? ? nil : c.children[3].attributes['href'].value.split('/').last
      end.compact
      away_players.delete_at(0)

      team_text = m.parent.at_css('.info div').xpath('text()').first.text.strip
      home_team = team_text.split('@').last.gsub(/[[:space:]]/, '')
      away_team = team_text.split('@').first.gsub(/[[:space:]]/, '')

      match = savant_lineups.select{|x| x[:home][:name].split(' ').join.include?(home_team)}.first
      home_match_is_home = match[:home][:name].split(' ').join.include?(home_team)
      home_pitcher_id   = home_match_is_home ? match[:home][:pitcher_id]   : match[:away][:pitcher_id]
      home_pitcher_name = home_match_is_home ? match[:home][:pitcher_name] : match[:away][:pitcher_name]
      away_match_is_home = match[:home][:name].split(' ').join.include?(away_team)
      away_pitcher_id   = away_match_is_home ? match[:home][:pitcher_id]   : match[:away][:pitcher_id]
      away_pitcher_name = away_match_is_home ? match[:home][:pitcher_name] : match[:away][:pitcher_name]

      {
        id: 'koko',
        home: {
          name: home_team,
          pitcher_id: home_pitcher_id,
          pitcher_name: home_pitcher_name,
          player_ids: home_players
        },
        away: {
          name: away_team,
          pitcher_id: away_pitcher_id,
          pitcher_name: away_pitcher_name,
          player_ids: away_players
        }
      }
    end
  end

  def stats
    all_lineups = lineups
    selenium_driver.quit rescue nil
    @selenium_driver = nil

    @batter_stats_cache = {}

    all_lineups.each_with_object([]) do |l, arr|
      puts "Fetching stats for #{l[:home][:name]} - #{l[:away][:name]}..."

      unless l[:home][:pitcher_id] && l[:away][:pitcher_id]
        puts 'Pitcher not found, match will be skipped'
        next
      else
        puts "#{l[:home][:pitcher_name]} vs #{l[:away][:pitcher_name]}"
      end

      home_row = pitcher_statcast(l[:home][:pitcher_id])
      away_row = pitcher_statcast(l[:away][:pitcher_id])

      # expected_statistics leaderboard: xera, est_woba
      # batted_ball leaderboard: brl_pa (barrel/PA %), ev95percent (hard hit %)
      # k_rate, bb_rate, whiff_rate not available via CSV — model falls back to league avg
      home_pitcher_era      = statcast_val(home_row, 'xera')
      away_pitcher_era      = statcast_val(away_row, 'xera')
      home_pitcher_k_rate   = 0.0
      away_pitcher_k_rate   = 0.0
      home_pitcher_bb_rate  = 0.0
      away_pitcher_bb_rate  = 0.0
      home_pitcher_hard_hit = statcast_val(home_row, 'ev95percent') / 100.0
      away_pitcher_hard_hit = statcast_val(away_row, 'ev95percent') / 100.0
      home_pitcher_barrel   = statcast_val(home_row, 'brl_pa') / 100.0
      away_pitcher_barrel   = statcast_val(away_row, 'brl_pa') / 100.0
      home_pitcher_whiff    = 0.0
      away_pitcher_whiff    = 0.0
      home_pitcher_xwoba    = statcast_val(home_row, 'est_woba')
      away_pitcher_xwoba    = statcast_val(away_row, 'est_woba')

      puts "Warning!!! #{l[:home][:pitcher_name]} has no ERA" if home_pitcher_era.zero?
      puts "Warning!!! #{l[:away][:pitcher_name]} has no ERA" if away_pitcher_era.zero?

      arr << {
        home_team: l[:home][:name],
        away_team: l[:away][:name],
        home_pitcher: {
          era:          home_pitcher_era,
          k_rate:       home_pitcher_k_rate,
          bb_rate:      home_pitcher_bb_rate,
          hard_hit_pct: home_pitcher_hard_hit,
          barrel_pct:   home_pitcher_barrel,
          whiff_pct:    home_pitcher_whiff,
          xwoba:        home_pitcher_xwoba,
          name:         l[:home][:pitcher_name],
          era_warning:  home_pitcher_era.zero?
        },
        away_pitcher: {
          era:          away_pitcher_era,
          k_rate:       away_pitcher_k_rate,
          bb_rate:      away_pitcher_bb_rate,
          hard_hit_pct: away_pitcher_hard_hit,
          barrel_pct:   away_pitcher_barrel,
          whiff_pct:    away_pitcher_whiff,
          xwoba:        away_pitcher_xwoba,
          name:         l[:away][:pitcher_name],
          era_warning:  away_pitcher_era.zero?
        },
        home_avg_rbi: l[:home][:player_ids].map { |rb| s = player_stats(rb); s&.children.to_a[11]&.text.to_f.then { |v| g = s&.children.to_a[3]&.text.to_f; g&.positive? ? v / g : nil } }.compact.select { |x| x.finite? && x > 0 && x < 1.5 },
        away_avg_rbi: l[:away][:player_ids].map { |rb| s = player_stats(rb); s&.children.to_a[11]&.text.to_f.then { |v| g = s&.children.to_a[3]&.text.to_f; g&.positive? ? v / g : nil } }.compact.select { |x| x.finite? && x > 0 && x < 1.5 }
      }
    end
  end

  # xERA + xwOBA from expected_statistics leaderboard
  def expected_stats_leaderboard
    @expected_stats_leaderboard ||= fetch_leaderboard(
      "https://baseballsavant.mlb.com/leaderboard/expected_statistics?type=pitcher&year=#{@proposal_date.year}&position=&team=&min=0&csv=true",
      'expected_statistics'
    )
  end

  # barrel% (brl_pa) + hard_hit% (ev95percent) from statcast batted ball leaderboard
  def batted_ball_leaderboard
    @batted_ball_leaderboard ||= fetch_leaderboard(
      "https://baseballsavant.mlb.com/leaderboard/statcast?type=pitcher&year=#{@proposal_date.year}&position=&team=&min=0&csv=true",
      'batted_ball'
    )
  end

  def fetch_leaderboard(url, name)
    puts "Fetching #{name} leaderboard..."
    response = HTTParty.get(url, timeout: 30, headers: { 'User-Agent' => 'Mozilla/5.0' })
    rows = CSV.parse(response.body.delete("\xEF\xBB\xBF"), headers: true)
    puts "#{name}: #{rows.length} rows, columns: #{rows.headers.join(', ')}"
    rows.each_with_object({}) { |row, h| h[row['player_id'].to_s] = row }
  rescue => e
    puts "Failed to fetch #{name} leaderboard: #{e.class} — #{e.message}"
    {}
  end

  def pitcher_statcast(player_id)
    id = player_id.to_s
    exp  = expected_stats_leaderboard[id]
    bball = batted_ball_leaderboard[id]
    puts "  Lookup #{player_id}: expected_stats=#{exp ? 'found' : 'MISSING'} batted_ball=#{bball ? 'found' : 'MISSING'}"
    { expected: exp, batted_ball: bball }
  end

  def statcast_val(data, key)
    row = data.is_a?(Hash) ? (key == 'xera' || key == 'est_woba' ? data[:expected] : data[:batted_ball]) : data
    return 0.0 unless row && row[key]
    row[key].to_f
  end

  def player_stats(player_id)
    @batter_stats_cache[player_id] ||= begin
      d = HTTParty.get("https://fantasydata.com/mlb/a-b-fantasy/#{player_id}", timeout: 120)
      Nokogiri::HTML(d.body).xpath("//*[@class='d-inline-block']")[1]
        &.children&.[](1)
        &.children&.[](7)
        &.children&.select{|x| x&.children&.first&.children&.first&.text == @proposal_date.year.to_s}
        &.first
    end
  end

  def selenium_driver
    @selenium_driver ||= begin
      options = Selenium::WebDriver::Options.chrome
      options.args << '--disable-search-engine-choice-screen'
      options.args << '--headless'
      options.args << '--no-sandbox'
      options.args << '--disable-dev-shm-usage'
      options.args << '--disable-gpu'
      options.args << '--disable-extensions'
      options.args << '--disable-default-apps'
      options.args << '--no-first-run'
      options.args << '--disable-background-networking'
      options.args << '--disable-sync'
      options.binary = ENV['CHROME_BIN'] if ENV['CHROME_BIN']
      Selenium::WebDriver.for(:chrome, options: options)
    end
  end

  def games_url
    "https://fantasydata.com/mlb/daily-lineups?date=#{@proposal_date.to_s}"
  end

  def savant_lineups
    @savant_lineups ||= begin
      data_json = HTTParty.get(savant_games_url, headers: { 'Content-Type' => 'application/json' })
      data_json.dig('schedule','dates')&.first['games'].map do |m|
        offense_team_id = data_json.dig('schedule','dates')&.first['games'].first.dig('linescore','offense','team','id')
        home_offense_mapping = offense_team_id == m.dig('teams', 'home', 'team', 'id') ? 'offense' : 'defense'
        away_offense_mapping = offense_team_id == m.dig('teams', 'away', 'team', 'id') ? 'offense' : 'defense'

        {
          id: m['gamePk'],
          home: {
            name: m.dig('teams', 'home', 'team', 'name'),
            pitcher_id: m.dig('teams', 'home', 'probablePitcher', 'id'),
            pitcher_name: m.dig('teams', 'home', 'probablePitcher', 'fullName'),
            player_ids: m.dig('linescore', home_offense_mapping)&.reject{|k, _| ['pitcher', 'batter', 'onDeck', 'inHole', 'team', 'battingOrder'].include?(k) }&.map{|_,v| v['id']},
          },
          away: {
            name: m.dig('teams', 'away', 'team', 'name'),
            pitcher_id: m.dig('teams', 'away', 'probablePitcher', 'id'),
            pitcher_name: m.dig('teams', 'away', 'probablePitcher', 'fullName'),
            player_ids: m.dig('linescore', away_offense_mapping)&.reject{|k, _| ['pitcher', 'batter', 'onDeck', 'inHole', 'team', 'battingOrder'].include?(k) }&.map{|_,v| v['id']},
          }
        }
      end
    end
  end

  def savant_games_url
    "https://baseballsavant.mlb.com/schedule?date=#{@proposal_date.to_s}"
  end
end
