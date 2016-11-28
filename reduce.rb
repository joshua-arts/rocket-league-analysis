=begin

Written by Joshua Arts for RL Analysis.

This code takes a large JSON file generated by Taylor Fausak's replay parser
Octane ( https://github.com/tfausak/octane ), reduces all the data into
meaningful data, then performs an analysis on that data to output a JSON file
containing stats that the game itself can't provide (like boost analysis,
possession numbers, etc).

If you see and missed calculations or errors, please let me know!

Also, lots of credit to Daniel Samuels. The way in which I read the Octane JSON
file and extracted that data was heavily inspired by the way he does it for
Rocket League Replays.

TODO:

player side of field data (stem off ball checking, will need to only count
    where play is on).
    
player air time
lb positions
boost pickups ("TAGame.VehiclePickup_Boost_TA")

fix scores
more accurate boost data
fix boost_data in OT.
test if kickoffs still correct after 0 second goal.
test proximity to ball every frame (not sure if can do)

=end

require 'json'

# - Variables to make a few lines shorter - #

$id_act = 'Engine.PlayerReplicationInfo:UniqueId'
$val = 'Value'

# - Helpers Methods - #

# Checks if an actor has a stat.
def check_for_stat(actor, stat)
    actor.has_key?(stat) ? actor[stat]['Value'] : 0
end

# Computes the points only score for a player.
def compute_points_score(actor)
    goals = check_for_stat(actor, 'TAGame.PRI_TA:MatchGoals')
    shots = check_for_stat(actor, 'TAGame.PRI_TA:MatchShots')
    assists = check_for_stat(actor, 'TAGame.PRI_TA:MatchAssists')
    saves = check_for_stat(actor, 'TAGame.PRI_TA:MatchSaves')
    # TODO: These values need tweaking...
    (goals * 100) + (assists * 50) + (saves * 50) + (shots * 30)
end

# Determines a players team.
def find_player_team(octane_stats, name)
    octane_stats.each{ |stats, ind|
        if stats['Name']['Value'] == name then
            return stats['Team']['Value'] == 1 ? "orange" : "blue"
        end
    }
    raise "ERROR: Couldn't find player_stats for " + name
end

# Selects the closest value in list to the target.
def select_closest(list, target)
    (list.map {|x| [(x.to_f - target).abs, x]}).min[1]
end

# Find the distance between positions a and b.
def distance(a, b)
    x = b['x'] - a['x']
    y = b['y'] - a['y']
    z = b['z'] - a['z']
    Math.sqrt((x ** 2) + (y ** 2) + (z ** 2))
end

# Takes a 2 element array and an element, returns the one you don't pass.
def opposite(arr, ind)
    return arr[1] if ind == 0
    arr[0]
end

class Replay

    attr_accessor :important_data

    # Keys to extract data from the metadata.
    @@meta_data_keys = ['MaxChannels', 'Team0Score', 'Team1Score', 'PlayerName', 'KeyframeDelay',
                      'MaxReplaySizeMB', 'NumFrames', 'MatchType', 'MapName', 'ReplayName',
                      'PrimaryPlayerTeam', 'Id', 'TeamSize', 'RecordFPS', 'Date']

    # Keys to extract data from player_stats.
    @@player_data_keys = ['Goals', 'Saves', 'Shots', 'Assists', 'Score', 'Team', 'bBot', 'Name']

    # WHY NO CAPITAL F PSYONIX!?
    # Keys to extract data from the goals.
    @@goal_data_keys = ['frame', 'PlayerName', 'PlayerTeam']

    def initialize(file_name)
        @file = File.read(file_name)
        @data = JSON.parse(@file)

        # Divide up the important data segments.
        @metadata = @data['Metadata']
        @player_stats = @metadata['PlayerStats']['Value']
        @goals = @metadata['Goals']['Value']
        @frames = @data['Frames']

        # Stores position_data for all important actors, and the ball.
        @position_data = {}
        @ball_only = {}

        # Stores the frames in which each player is closest to the ball.
        @frames_closest_raw = []
        @frames_closest = {}

        # Stores the various types of actors we find on each frame.
        @actors = {}
        @player_actors = {}
        @position_actors = {}

        # Maps player car objects to player id's.
        @player_cars = {}

        # Maps team data to their team ID in actors.
        @team_info = {}

        # Maps the current frame to the players boost value.
        @boost_data = {}
        @unknown_boost_data = {}
        @time_boost_data = {}

        # Maps current frame to the time remaining on the clock.
        @time_map = {}
        @ball_over_time = {}
        @time_position_data = {}

        # JSON Object to store the important_data
        @important_data = {'metadata' => {},
                          'player_data' => {},
                          'team_data' => {
                              'orange' => {},
                              'blue' => {}
                          },
                          'goal_data' => {},
                          'extra_data' => {}
                          }

        # Extra data needed in analysis.
        # NOTE: Might be able to be local to get_frames()?
        @ball_hit = false
        @ball_spawned = false
        @cars_frozen = false
        @ball = nil
        @ball_actor_id = nil

        # Needed extra data.
        @overtime = false
        @kickoff_time_delay = 2
        @orange_kickoffs = 0
        @blue_kickoffs = 0
    end

    def to_s
        JSON.pretty_generate(@important_data)
    end

    # Read replay metadata.
    def get_metadata()
        @@meta_data_keys.each{ |key|
            @important_data['metadata'][key] = (@metadata[key]) ? @metadata[key]['Value'] : 0
        }
    end

    # Read replay goal data.
    def get_goals()
        @goals.each_with_index{ |goal, ind|
            goal_data = {}
            @@goal_data_keys.each{ |key|
                goal_data[key] = goal[key]['Value']
            }
            @important_data['goal_data'][ind] = goal_data
        }
    end

    # Read replay frame data (positions, boost data, etc).
    def get_frames()
        @frames.each_with_index{ |frame, i|

            # Create new frame instances for position objects.
            # NOTE: Change to use JSON objects.
            @position_data[i] = []
            @ball_only[i] = []

            ball_hit = false
            ball_spawned = false

            lowest_dist = 2000000
            lowest_dist_player = nil

            # Get new actors.
            spawned = frame['Spawned'] if frame['Spawned']

            # Get updated actors.
            updated = frame['Updated'] if frame['Updated']

            # Get deleted actors.
            deleted = frame['Destroyed'] if frame['Destoryed']

            handle_spawned_actors(spawned, i) if spawned
            handle_updated_actors(updated, i) if updated
            handle_deleted_actors(deleted, i) if deleted
            handle_merged_actors(spawned.merge(updated), i)
        }
    end

    def handle_spawned_actors(spawned, frame)
        spawned.each{ |key, s_actor|

            # Add the actor since it just spawned.
            @actors[key] = s_actor if !@actors.has_key?(key)

            if s_actor.has_key?("Engine.Pawn:PlayerReplicationInfo") then
                player_actor_id = s_actor['Engine.Pawn:PlayerReplicationInfo']['Value']['Int']
                @player_cars[player_actor_id] = key
            end

            # Might always be true? Doesn't hurt to check.
            if s_actor.has_key?('Class') then
                # Player join actor.
                if s_actor['Class'] == "TAGame.PRI_TA" then
                    @player_actors[key] = s_actor
                    # NOTE: Might not be needed.
                    @player_actors[key]['join_frame'] = frame
                end

                # Ball spawned actor.
                if s_actor['Class'] == "TAGame.Ball_TA" then
                    ball_spawned = true
                end

                # Team info actor.
                if s_actor['Class'] == 'TAGame.Team_Soccar_TA' then
                    @team_info[key] = s_actor['Name']
                end
            end

            # more stuff here.
        }
    end

    def handle_updated_actors(updated, frame)
        updated.each{ |key, u_actor|

            # Make sure there are changes in the updated actor.
            if (@actors[key] != u_actor) then

                # Merge existing actor with changes.
                @actors[key] = @actors[key].merge(u_actor)

                if @player_actors.has_key?(key) then
                    @player_actors[key] = @actors[key]
                end
            end

            if u_actor.has_key?("Engine.Pawn:PlayerReplicationInfo") then
                player_actor_id = u_actor['Engine.Pawn:PlayerReplicationInfo']['Value']['Int']
                @player_cars[player_actor_id] = key
            end
        }
    end

    def handle_deleted_actors(deleted, frame)
        if deleted then
            deleted.each{ |key, d_actor|
                @actors.delete(key) if @actors.has_key?(key)
                # NOTE: Also potentially uneeded.
                @player_actors[key]['leave_frame'] = frame if @player_actors.has_key?(key)
            }
        end
    end

    def handle_merged_actors(merged, frame)
        real_player = nil

        # Go through all actors that have been affected during this frame.
        merged.each{ |key, actor_data|
            # Check for position data.
            if actor_data.has_key?('TAGame.RBActor_TA:ReplicatedRBState') then
                @position_actors[key] = actor_data['TAGame.RBActor_TA:ReplicatedRBState']['Value']['Position']

                @player_cars.each{ |player_key, car_key|
                    if car_key == key then
                        real_player = player_key
                        break
                    end
                }

                real_player = "ball" if @player_cars.key(key) == nil

                pos_data = actor_data['TAGame.RBActor_TA:ReplicatedRBState']['Value']['Position']
                rot_data = actor_data['TAGame.RBActor_TA:ReplicatedRBState']['Value']['Rotation']

                # Create new position instance for player at frame.
                pos_instance = {
                    'id' => real_player,
                    'x' => pos_data[0],
                    'y' => pos_data[1],
                    'z' => pos_data[2],
                    'yaw' => rot_data[0],
                    'pitch' => rot_data[1],
                    'roll' => rot_data[2]
                }

                @position_data[frame] << pos_instance
                @ball_only[frame] << pos_instance if real_player == "ball"

            end

            if actor_data.has_key?('TAGame.CarComponent_Boost_TA:ReplicatedBoostAmount') then
                boost_value = actor_data['TAGame.CarComponent_Boost_TA:ReplicatedBoostAmount']['Value']
                raise "ERROR: Boost value is out of bounds." if boost_value < 0 or boost_value > 255

                @boost_data[key] = {} if !@boost_data.has_key?(key)

                if !@actors[key].has_key?('TAGame.CarComponent_TA:Vehicle') then

                    @unknown_boost_data[key] = {} if !@unknown_boost_data.has_key?(key)
                    @unknown_boost_data[key][frame] = boost_value

                else

                    # Find the car that the boost data belongs to.
                    car_id = @actors[key]['TAGame.CarComponent_TA:Vehicle']['Value']['Int']

                    player_id = @player_cars.key(car_id.to_s)

                    @boost_data[player_id] = {} if !@boost_data.has_key?(player_id)

                    @boost_data[player_id][frame] = boost_value

                    # Get floating data.
                    if @unknown_boost_data.has_key?(key) then
                        @unknown_boost_data[key].each{ |f_ind, boost|
                            @boost_data[player_id][f_ind] = boost
                        }
                        @unknown_boost_data.delete(key)
                    end

                end

            end

            search_actors(actor_data, frame)
        }

        # NOTE: Add all this to a function but I doon't think we need it.
        @ball_actor_id = nil
        @ball = nil
        @ball_hit = false

        # Find the ball.
        @actors.each{ |key, actor_data|
            if actor_data['Class'] == "TAGame.Ball_TA" then
                @ball_actor_id = key
                @ball = actor_data
                break
            end
        }

        # Get data from the ball if it has changed.
        # NOTE: Remove this velocity stuff?
        old_velocity = 0
        if(@ball and @ball.has_key?('TAGame.RBActor_TA:ReplicatedRBState')) then
            new_velocity = @ball['TAGame.RBActor_TA:ReplicatedRBState']['Value']['AngularVelocity']

            ball_hit = true if new_velocity != old_velocity
            old_velocity = new_velocity

        end

    end

    # Search for specific actors that contain data we need to keep track of.
    def search_actors(actor_data, frame)
        # Map frames to timer.
        if actor_data.has_key?('TAGame.GameEvent_Soccar_TA:SecondsRemaining') then
            @time_map[frame] = actor_data['TAGame.GameEvent_Soccar_TA:SecondsRemaining']['Value']
        end

        # Detrmine current state at current frame.
        if actor_data.has_key?('TAGame.GameEvent_TA:ReplicatedGameStateTimeRemaining') then
            if actor_data['TAGame.GameEvent_TA:ReplicatedGameStateTimeRemaining']['Value'] == 3 then
                @cars_frozen = true
            elsif actor_data['TAGame.GameEvent_TA:ReplicatedGameStateTimeRemaining']['Value'] == 0 then
                @cars_frozen = false
            end
        end

        # Get server name.
        if actor_data.has_key?('Engine.GameReplicationInfo:ServerName') then
            @important_data['extra_data']['Server_Name'] = actor_data['Engine.GameReplicationInfo:ServerName']['Value']
        end

        # Get max team size.
        if actor_data.has_key?('TAGame.GameEvent_Team_TA:MaxTeamSize') then
            @important_data['extra_data']['Max_Team_Size'] = actor_data['TAGame.GameEvent_Team_TA:MaxTeamSize']['Value']
        end
    end

    # - Analysis Methods - #

    def analyze()
        # If the clock has 1 seconds twice, we went into overtime.
        @overtime = (@time_map.values.count(1) > 1)
        @important_data['extra_data']['Overtime'] = @overtime

        # A list a players who have cars (excludes spectators).
        playing_players = @player_cars.keys

        # Extracts data from the actors and records for each playing player.
        record_player_data(playing_players)

        # Record boost data (avg boost) for each player.
        record_boost_data(playing_players)

        # Map the ball position to the clock.
        map_position_data_over_time()
        map_ball_position_over_time()

        # Record the amount of team the ball is in each zone.
        record_zone_time_frames()
        # record_zone_time_mapped()

        # Determine who won each kickoff.
        record_kickoffs()

        # Calculate closest player to the ball at each second.
        record_ball_proximity()

        # Determine who scored the game-winning goal.
        find_game_winning_goal()

        # Determine who got MVP.
        find_mvp()

        # Record team data.
        record_team_data()
    end

    def record_player_data(playing_players)
        @player_actors.each{ |key, actor|
            if playing_players.include?(key.to_i) then
                player_data = {
                    'Name' => actor['Engine.PlayerReplicationInfo:PlayerName']['Value'],
                    'Score' => check_for_stat(actor, 'TAGame.PRI_TA:MatchScore'),
                    'Goals' => check_for_stat(actor, 'TAGame.PRI_TA:MatchGoals'),
                    'Shots' => check_for_stat(actor, 'TAGame.PRI_TA:MatchShots'),
                    'Assists' => check_for_stat(actor, 'TAGame.PRI_TA:MatchAssists'),
                    'Saves' => check_for_stat(actor, 'TAGame.PRI_TA:MatchSaves'),
                    'Points_Score' => compute_points_score(actor),
                    'Play_Score' => check_for_stat(actor, 'TAGame.PRI_TA:MatchScore') - compute_points_score(actor),
                    'ID' => actor[$id_act]['Value']['Remote']['Value'],
                    'Team' => find_player_team(@player_stats, actor['Engine.PlayerReplicationInfo:PlayerName']['Value'])}
                @important_data['player_data'][player_data['ID']] = player_data
            end
        }
    end

    def record_boost_data(playing_players)
        # Clean spectators and non playing players from boost data.
        @boost_data.each{ |id, boost_obj|
            @boost_data.delete(id) unless playing_players.include?(id)
        }

        mapped_boost_data = {}

        # Record boost data by player.
        @player_actors.each{ |key, actor|
            # Ignore spectators and such.
            if @boost_data.has_key?(key.to_i) then
                mapped_boost_data[actor[$id_act]['Value']['Remote']['Value']] = @boost_data[key.to_i]
            end
        }

        # The boost data has already been mapped to players, now we map it to the clock.
        # NOTE: Seems to be not mapping all the boost data correctly.
        mapped_boost_data.each{ |uuID, b_data|
            temp_data = {}
            b_data.each{ |frame, boost|
                time_key = select_closest(@time_map.keys, frame)
                temp_data[@time_map[time_key]] = boost
            }
            @time_boost_data[uuID] = temp_data
        }

        # Calculate average boost.
        uuIDS = mapped_boost_data.keys
        inc = 0
        @time_boost_data.each{ |player_platform_id, boost_set|
            avg_boost_ratio = (boost_set.values.inject(0){|sum,x| sum + x } / boost_set.values.length)
            avg_boost = ((avg_boost_ratio / 255.0) * 100).round
            @important_data['player_data'][uuIDS[inc]]['AVG_Boost'] = avg_boost
            inc += 1
        }

        # NOTE: Uncomment this to add boost_data to the JSON.
        #@important_data['boost_data'] = mapped_boost_data

        mapped_boost_data.each{ |uuID, b_data|
            temp_data = {}
            b_data.each{ |frame, boost|
                time_key = select_closest(@time_map.keys, frame)
                temp_data[@time_map[time_key]] = boost
            }
            @time_boost_data[uuID] = temp_data
        }
    end

    # TODO: Merge the following to functions to map_over_time()

    def map_position_data_over_time()
        # Map position data to time.
        overtime_on = false
        @position_data.each{ |frame, p_data|
            time_key = select_closest(@time_map.keys, frame)
            if overtime_on then
                @time_position_data[0 - @time_map[time_key]] = p_data
            else
                @time_position_data[@time_map[time_key]] = p_data
            end
            @time_position_data[@time_map[time_key]] = p_data
            overtime_on = true if @time_map[time_key] == 0
        }
    end

    def map_ball_position_over_time()
        # Map ball postion data to time.
        overtime_log = {}
        overtime_on = false
        @ball_only.each{ |frame, p_data|
            time_key = select_closest(@time_map.keys, frame)
            if overtime_on then
                @ball_over_time[0 - @time_map[time_key]] = p_data[0]
            else
                @ball_over_time[@time_map[time_key]] = p_data[0]
            end
            @ball_over_time[@time_map[time_key]] = p_data[0]
            overtime_on = true if @time_map[time_key] == 0
        }
    end

    def record_zone_time_mapped()
        # Determine what side of the field the ball is on.
        blue_seconds = orange_seconds = exact_zero = 0
        @ball_over_time.each{ |time, data|
            if data == nil then
                exact_zero = exact_zero + 1
                next
            end
            if data['y'] > 0 then
                orange_seconds = orange_seconds + 1
            elsif data['y'] < 0 then
                blue_seconds = blue_seconds + 1
            else
                exact_zero = exact_zero + 1
            end
        }

        # Just divide the extra faceoff seconds up.
        # Allocate the extra one to a team if needed.
        if exact_zero % 2 == 0 and exact_zero > 0 then
            blue_seconds = blue_seconds + (exact_zero / 2)
            orange_seconds = orange_seconds + (exact_zero / 2)
        else
            exact_zero = exact_zero - 1
            blue_seconds = blue_seconds + (exact_zero / 2)
            orange_seconds = orange_seconds + (exact_zero / 2) + 1
        end

        times  = [orange_seconds, blue_seconds]
        num_seconds = orange_seconds + blue_seconds

        ['orange', 'blue'].each_with_index{ |team, i|
            @important_data['team_data'][team]['Attack_Time'] = times[i]
            @important_data['team_data'][team]['Defense_Time'] = opposite(times, i)
            @important_data['team_data'][team]['Attack_%'] = ((times[i].to_f / num_seconds) * 100.0).round
            @important_data['team_data'][team]['Defense_%'] = ((opposite(times, i).to_f / num_seconds) * 100.0).round
        }
    end

    def record_zone_time_frames()
        orange_frames = blue_frames = 0
        @ball_only.each{ |frame, pos_data|
            data = pos_data[0]
            next if data == nil
            if data['y'] > 0 then
                orange_frames = orange_frames + 1
            elsif data['y'] < 0 then
                blue_frames = blue_frames + 1
            end
        }

        frame_arr  = [orange_frames, blue_frames]
        num_frames = orange_frames + blue_frames

        ['orange', 'blue'].each_with_index{ |team, i|
            @important_data['team_data'][team]['Attack_Time'] = ((@time_map.keys.length / num_frames.to_f) * frame_arr[i]).round(2)
            @important_data['team_data'][team]['Defense_Time'] = ((@time_map.keys.length / num_frames.to_f) * opposite(frame_arr, i)).round(2)
            @important_data['team_data'][team]['Attack_%'] = ((frame_arr[i].to_f / num_frames) * 100.0).round(2)
            @important_data['team_data'][team]['Defense_%'] = ((opposite(frame_arr, i).to_f / num_frames) * 100.0).round(2)
        }
    end

    def tally_kickoff(second)
        if @ball_over_time[second]['y'] > 0 then
            @blue_kickoffs = @blue_kickoffs + 1
        elsif @ball_over_time[second]['y'] < 0 then
            @orange_kickoffs = @orange_kickoffs + 1
        else
            raise "ERROR: Ball position still zero when checking kickoff result."
        end
    end

    def record_kickoffs()
        goals_to_check = @important_data['goal_data'].values

        # Exclude last overtime goal if overtime occured.
        goals_to_check.pop if @overtime

        goals_to_check.each{ |data|
            # TODO: Needs to be seconds closest without going over...
            # Find the second to check position.
            kickoff_check = (@time_map[select_closest(@time_map.keys, data['frame'])] - @kickoff_time_delay)
            if(@ball_over_time.has_key?(kickoff_check)) then
                tally_kickoff(kickoff_check)
            else
                raise "ERROR: Can't find position data for second after kickoff."
            end
        }

        # NOTE: Can you score in a second? If so I need to check here then...

        # Tally the first kickoff a second after the faceoff.
        if @ball_over_time.has_key?(299) then
            tally_kickoff(299)
        end

        # Tally the overtime kickoff a second after the faceoff if it happened.
        if @overtime && @ball_over_time.has_key?(-1) then
            tally_kickoff(-1)
        end

        # Record total kickoffs in extra_data.
        @important_data['extra_data']['Kickoffs'] = @orange_kickoffs + @blue_kickoffs
        @important_data['team_data']['orange']['Kickoff_Wins'] = @orange_kickoffs
        @important_data['team_data']['blue']['Kickoff_Wins'] = @blue_kickoffs
    end

    def record_ball_proximity()
        # TODO: Make it so if the play doesn't have position data at that second, use last second.
        @time_position_data.each{ |frame, data|
            ball_points = nil
            low = 20000000;
            low_player = nil

            # Find the ball points at that frame.
            data.each{ |set, set_num|
                if set['id'] == "ball" then
                    ball_points = set
                    break
                end
            }

            next if ball_points == nil

            data.each{ |set, set_num|
                if set['id'] != "ball" then
                    dist = distance(set, ball_points)

                    if dist < low then
                        low = dist
                        low_player = set['id']
                    end
                end
            }

            @player_actors.each{ |key, actor|
                if key.to_i == low_player.to_i then
                    @frames_closest_raw << low_player
                    break
                end
            }
        }

        # Count the closest player data and add it.
        data_id = 0
        @frames_closest_raw.each{ |player_id|
            @player_actors.each{ |key, actor|
                if key.to_i == player_id.to_i then
                    data_id = actor[$id_act][$val]['Remote'][$val]
                    @important_data['player_data'][data_id]['Frames_Closest'] = 0 unless @important_data['player_data'][data_id].has_key?('Frames_Closest')
                    @important_data['player_data'][data_id]['Frames_Closest'] = @important_data['player_data'][data_id]['Frames_Closest'] + 1
                    break
                end
            }
        }

        # Record as a percentage.
        @important_data['player_data'].each{ |uuID, player|
            player['Closest_Percent'] = ((player['Frames_Closest'].to_f / @frames_closest_raw.length) * 100.0).round
        }
    end

    def find_game_winning_goal()
        team_one = team_two = 0
        even = true
        gwg_name = ""

        @important_data['goal_data'].each{ |goal_num, goal_info|
            gwg_name = goal_info['PlayerName'] if even
            if goal_info['PlayerTeam'] == "1" then
                team_one = team_one + 1
            else
                team_two = team_two + 1
            end
            even = (team_one == team_two)
        }

        @important_data['extra_data']['GWG_Name'] = gwg_name
        # TODO: Add GWG by ID.
    end

    def find_mvp()
        score_data = {}
        @important_data['player_data'].each{ |player_num, player_info|
            score_data[player_info['ID']] = player_info['Score']
        }

        # TODO: Deal with two players having the same score (by goals, assists, etc.)
        # make sure max player is on winning team.

        mvp_id = score_data.key(score_data.values.max)

        important_data['player_data'].each{ |player_num, player_info|
            player_info['MVP'] = (mvp_id == player_num)
        }

        @important_data['extra_data']['MVP_Name'] = @important_data['player_data'][mvp_id]['Name']
        @important_data['extra_data']['MVP_ID'] = mvp_id
    end

    def record_team_data()
        orange = {}
        blue = {}
        @important_data['player_data'].each{ |uuID, player|
            if player['Team'] == 'orange' then
                orange[uuID] = player
            else
                blue[uuID] = player
            end
        }
        @important_data['player_data'] = {'orange' => orange, 'blue' => blue}

        # Get team stats...
        num_seconds = @time_map.keys.length - 1
        @important_data['player_data'].each{ |team, players_by_team|
            team_score = team_boost = team_goals = team_assists = team_saves = team_shots = 0
            team_points_score = team_play_score = team_possession = 0
            players_by_team.each{ |uuID, player|
                team_score += player['Score']
                team_boost += player['AVG_Boost']
                team_goals += player['Goals']
                team_assists += player['Assists']
                team_saves += player['Saves']
                team_shots += player['Shots']
                team_points_score += player['Points_Score']
                team_play_score += player['Play_Score']
                team_possession += player['Frames_Closest']
            }
            short = @important_data['team_data'][team]
            short['Score'] = team_score
            short['AVG_Score'] = (team_score / 3).round
            short['AVG_Boost'] = (team_boost / 3).round
            short['Goals'] = team_goals
            short['Assists'] = team_assists
            short['Saves'] = team_saves
            short['Shots'] = team_shots
            short['Points_Score'] = team_points_score
            short['Play_Score'] = team_play_score
            short['Frames_Closest'] = team_possession
            short['Closest_Percent'] = ((team_possession.to_f / @frames_closest_raw.length) * 100.0).round
        }
    end

end

# - Read Data - #

replay = Replay.new('./output.json')

replay.get_metadata()
replay.get_goals()
replay.get_frames()

# - Analyze Data - #

replay.analyze()
puts replay.to_s
