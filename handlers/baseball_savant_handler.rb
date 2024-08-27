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
      home_pitcher_era = player_stats(l[:home][:pitcher_id])[player_stats(l[:home][:pitcher_id]).index{|x| x.text == 'xERA'} + 1].text.to_f
      away_pitcher_era = player_stats(l[:away][:pitcher_id])[player_stats(l[:away][:pitcher_id]).index{|x| x.text == 'xERA'} + 1].text.to_f

      arr <<
        {
          home_team: l[:home][:name],
          away_team: l[:away][:name],
          home_pitcher: {
            era:  home_pitcher_era,
            name: l[:home][:pitcher_name],
            era_warning: home_pitcher_era&.zero?
            #avg_ko: player_stats(l[:home][:pitcher_id])['Data'].first['PitchingStrikeouts'] / player_stats(l[:home][:pitcher_id])['Data'].first['Games'].to_f
          },
          away_pitcher: {
            era: away_pitcher_era,
            name: l[:away][:pitcher_name],
            era_warning: away_pitcher_era&.zero?
            #avg_ko: player_stats(l[:away][:pitcher_id])['Data'].first['PitchingStrikeouts'] / player_stats(l[:away][:pitcher_id])['Data'].first['Games'].to_f
          },
          home_avg_rbi: l[:home][:player_ids].map { |rb| player_stats(rb)&.children.to_a[10]&.text.to_f / player_stats(rb)&.children.to_a[3]&.text.to_f },
          away_avg_rbi: l[:away][:player_ids].map { |rb| player_stats(rb)&.children.to_a[10]&.text.to_f / player_stats(rb)&.children.to_a[3]&.text.to_f },
          home_odd: nil,
          away_odd: nil
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
    "https://baseballsavant.mlb.com/schedule?date=#{Date.today.to_s}"
  end

  def player_stat_url(player_id)
    "https://baseballsavant.mlb.com/savant-player/#{player_id}?stats=statcast-r-pitching-mlb"
  end
end
