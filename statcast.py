from pybaseball import pitching_stats
from pybaseball import playerid_reverse_lookup

import sys

# Function to get xERA for a given player ID and year
def get_xera(player_id, year):
    # Fetch the full pitching stats for the given year
    fgID = playerid_reverse_lookup([player_id], key_type='mlbam').iat[0, 5];0
    stats = pitching_stats(2024, qual=0)
    player_stats = stats[stats['IDfg'] == int(fgID)]

    if not player_stats.empty:
        # Extract the xERA for the player
        print(player_stats['ERA'])
        print(player_stats['xERA'].values[0])
    else:
        print(f"No data found for Player ID {player_id} in {year}")

if __name__ == "__main__":
    # Take in player_id and year from the command line
    player_id = int(sys.argv[1])
    year = sys.argv[2]

    # Fetch and print xERA for the player
    get_xera(player_id, year)
