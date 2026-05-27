require_relative './base_handler.rb'
require 'csv'

class BaseballSavantHandler < BaseHandler
  def stats
    lineups.each_with_object([]) do |l, arr|
      @cached_stats = {}

      puts "Fetching stats for #{l[:home][:name]} - #{l[:away][:name]}..."

      unless l[:home][:pitcher_id] && l[:away][:pitcher_id]
        puts 'Pitcher not found, match will be skipped'
        next
      else
        puts "#{l[:home][:pitcher_name]} vs #{l[:away][:pitcher_name]}"
      end
      home_nodes = player_stats(l[:home][:pitcher_id])
      away_nodes = player_stats(l[:away][:pitcher_id])

      home_pitcher_era      = extract_pitcher_stat(home_nodes, 'xERA')
      away_pitcher_era      = extract_pitcher_stat(away_nodes, 'xERA')
      home_pitcher_k_rate   = extract_pitcher_stat(home_nodes, 'K %') / 100.0
      away_pitcher_k_rate   = extract_pitcher_stat(away_nodes, 'K %') / 100.0
      home_pitcher_bb_rate  = extract_pitcher_stat(home_nodes, 'BB %') / 100.0
      away_pitcher_bb_rate  = extract_pitcher_stat(away_nodes, 'BB %') / 100.0
      home_pitcher_hard_hit = extract_pitcher_stat(home_nodes, 'Hard Hit%') / 100.0
      away_pitcher_hard_hit = extract_pitcher_stat(away_nodes, 'Hard Hit%') / 100.0
      home_pitcher_barrel   = extract_pitcher_stat(home_nodes, 'Barrel %') / 100.0
      away_pitcher_barrel   = extract_pitcher_stat(away_nodes, 'Barrel %') / 100.0
      home_pitcher_whiff    = extract_pitcher_stat(home_nodes, 'Whiff %') / 100.0
      away_pitcher_whiff    = extract_pitcher_stat(away_nodes, 'Whiff %') / 100.0
      home_pitcher_xwoba    = extract_pitcher_stat(home_nodes, 'xwOBA')
      away_pitcher_xwoba    = extract_pitcher_stat(away_nodes, 'xwOBA')

      arr <<
        {
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
            era_warning:  home_pitcher_era&.zero?
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
            era_warning:  away_pitcher_era&.zero?
          },
          home_avg_rbi: l[:home][:player_ids].map { |rb| player_stats(rb)&.children.to_a[10]&.text.to_f / player_stats(rb)&.children.to_a[3]&.text.to_f },
          away_avg_rbi: l[:away][:player_ids].map { |rb| player_stats(rb)&.children.to_a[10]&.text.to_f / player_stats(rb)&.children.to_a[3]&.text.to_f }
        }
    end
  end

  def player_stats(player_id)
    @cached_stats[player_id] || begin
      options = Selenium::WebDriver::Options.chrome
      options.args << '--disable-search-engine-choice-screen'
      driver = Selenium::WebDriver.for(:chrome, options: options)
      driver.navigate.to player_stat_url(player_id)
      elements = driver.find_element(id: "percentile-slider-viz").attribute("innerHTML")
      driver.close
      @cached_stats[player_id] = Nokogiri::XML(elements).xpath("//text")
      @cached_stats[player_id]
    end
  end

  def lineups
    data_json = HTTParty.get(games_url, headers: { 'Content-Type' => 'application/json' })
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

  def games_url
    "https://baseballsavant.mlb.com/schedule?date=#{@proposal_date.to_s}"
  end

  def player_stat_url(player_id)
    "https://baseballsavant.mlb.com/savant-player/#{player_id}?stats=statcast-r-pitching-mlb"
  end
end
