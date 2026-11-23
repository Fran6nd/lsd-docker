/* vocab.h -- The words a behaviour tree may use
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * THIS IS THE ENGINE'S WHOLE INTERFACE TO BEHAVIOUR. A tree (bt.h) is
 * made of these names and nothing else: a gamemode's author reads this
 * file, not the engine. So the words are few, named for what they do and
 * never for who uses them, and each has one line here. A mode that needs
 * a new word adds it HERE, neutral, with a test -- never an `if (mode)`
 * in the engine.
 *
 * Everything a condition or a score says about an ENEMY is what the bot
 * itself perceives (senses.h): in sight, remembered, heard, or told by
 * its team -- never what the server knows.
 *
 * TRAITS, for `option <trait> ...`: persona.h's names -- none,
 * aggression, caution, objective, teamwork, builder, marksman, flank,
 * stealth, curiosity, greed.
 *
 * PLACES, for go_to / hold / ping / use / knows / at:
 *   self          where it stands
 *   enemy         the man it fights, else the nearest in sight, else the
 *                 nearest it knows of
 *   group         (or enemy_group) the middle of two or more enemies
 *                 within 6 of one another
 *   last_seen     where somebody left its sight
 *   noise         what it heard
 *   threat        where a hit seemed to come from
 *   search        the freshest of the last three, or a told sighting
 *   ping          the ping it answers (the caller himself for a call
 *                 for help);  caller: the one who pinged
 *   order         where the server's order points
 *   mate          the nearest team-mate
 *   cover         the nearest place the enemy cannot see
 *   hot           where its team last met the other
 *   own_base, enemy_base, own_intel, enemy_intel   the game's objects
 *
 * TWO TREES A BOT. The tree named by the setting `tree` (say "tdm") is
 * the bot's MAIN tree: what it is doing. If the same text also has a
 * tree called "<name>_also" ("tdm_also"), it is ticked just before the
 * main one at every decision: that is where the things done BESIDE go --
 * the lamp, a ping, an item -- because bt.h's seq and select remember
 * where they were and would not come back to them while a fight is
 * RUNNING. Keep "_also" trees to actions that end at once.
 *
 * THE ITEMS TREE. `tree items` is always there to be included: the
 * engine writes it from what each inventory item brought with it
 * (engine.c). It fails at once for a bot with nothing to use.
 * THE EXTRAS TREE, `tree extras`, likewise: what the server's scripts
 * add to every bot (extra.<name>.tree), each part ticked at every
 * decision.
 *
 * NIGHT AND LAMPS ARE NOT THE ENGINE'S. The words is_night, lamp_on,
 * has_night_vision, night, night_vision, hit_in_dark and `do lamp` are
 * here for the fragment a server's night script sends as an extra; the
 * trees shipped in trees/ use none of them, and a bot never lights a
 * lamp unless a tree tells it to.
 *
 * CONDITIONS  (if / unless)
 *   enemy_visible                      an enemy is in this bot's sight now
 *   enemy_known                        an enemy is in sight, remembered, or
 *                                      told of by the team
 *   enemy_within <voxels>              the nearest enemy in sight is nearer
 *                                      than that
 *   enemy_beyond <voxels>              an enemy is in sight and the nearest is
 *                                      farther than that
 *   enemies_grouped <count> <radius>   that many known enemies stand within
 *                                      radius of one another
 *   target_in_cover                    the man being fought was seen under 5 s
 *                                      ago and is out of sight now
 *   outnumbered                        more enemies in sight than team-mates
 *                                      within 20, itself included
 *   health_below <hp>                  its health is under that (of 100)
 *   hurt_recently [secs]               it lost health within that many seconds
 *                                      (default 3)
 *   ammo_below <fraction>              rounds left, magazine and reserve, are
 *                                      under that fraction of a full load
 *   ammo_out                           no round left at all
 *   has_grenade                        it carries a grenade
 *   grenade_worth                      it has a grenade, is not just done
 *                                      throwing, and something is worth one (a
 *                                      group, a far man, a place just lost)
 *   grenade_near                       an enemy grenade it has noticed would
 *                                      hurt it where it stands
 *   heard_noise                        a noise it heard is still worth going to
 *   lost_enemy                         somebody left its sight and the place is
 *                                      still fresh
 *   has_search                         there is a place worth searching: a lost
 *                                      man, a hit's source, a noise, a told
 *                                      sighting
 *   alert <calm|suspicious|engaged>    its alertness is that
 *   ping_called [enemy|help|go]        a team-mate's ping was given to this bot
 *                                      to answer (of that kind, if said)
 *   has_order                          the server gave it an order that stands
 *   is_night                           it is night
 *   has_night_vision                   it sees by night as by day (the setting
 *                                      night_vision)
 *   lamp_on                            its flashlight is lit
 *   has_item <name>                    it holds at least one of that inventory
 *                                      item
 *   sky_clear                          nothing solid above its head (a thing
 *                                      that comes down from the sky needs it)
 *   allies_hurt_near <radius>          a team-mate under 50 health is within
 *                                      radius
 *   mate_within <voxels>               a live team-mate is that near
 *   alone [voxels]                     no live team-mate within that (default
 *                                      25)
 *   spotted_new                        it has just seen an enemy its team did
 *                                      not know of
 *   losing                             it is in a fight, under 45 health and
 *                                      outnumbered, or under 30 and just hit
 *   sniped                             it was hit within 3 s from more than 50
 *                                      voxels away
 *   setting <key> [value]              the gamemode's setting <key> is set (to
 *                                      <value>, if said): how a mode's tree
 *                                      reads the mode's own rules
 *   chance <0..1>                      true that often, by the bot's own dice
 *   knows <place>                      the bot knows of such a place now (see
 *                                      the places below)
 *   at <place> [voxels]                it is within that of the place (default
 *                                      4)
 *
 * SCORES  (option <trait> <score>), each 0..1
 *   always                             1
 *   enemy_visible                      1 with an enemy in sight, else 0
 *   enemy_known                        how sure it is of an enemy it cannot
 *                                      see: 1 fresh, fading to 0; 0 with one in
 *                                      sight
 *   enemy_near [voxels]                1 with an enemy in sight at arm's
 *                                      length, falling to 0 at that distance
 *                                      (default 60)
 *   hurt                               health lost: 0 unhurt, 1 nearly dead
 *   hurt_in_fight                      health lost, counted only with an enemy
 *                                      in sight or a hit from somewhere in the
 *                                      last 3 s; 0 for 6 s after a retreat
 *   healthy                            health left, 0 to 1
 *   search                             how fresh the place most worth searching
 *                                      is: 1 just now, 0 none
 *   ping_called                        1 while a team-mate's ping is this bot's
 *                                      to answer
 *   has_order                          1 while an order stands
 *   alone [voxels]                     0 beside a team-mate, rising to 1 at
 *                                      that distance (default 40) or with none
 *                                      alive
 *   grenade_worth                      1 when a grenade is worth throwing now
 *                                      (see the condition)
 *   grenade_near                       1 when an enemy grenade would hurt it
 *                                      here
 *   outnumbered                        0 when not; else how badly, up to 1
 *   night_vision                       1 by night for a bot that has night vision
 *   hit_in_dark                        1 by night for a bot with no night vision
 *                                      and its lamp out, hit in the last 5 s
 *   night                              1 by night
 *   calm                               1 when nothing is known, 0.3 when
 *                                      suspicious, 0 engaged
 *   has_item <name>                    1 if it holds one
 *   ammo_low                           0 with a full load, 1 with none
 *
 * ACTIONS  (do)
 *   fight                              fight the enemy it has chosen (nearest
 *                                      in sight, kept until another is at half
 *                                      his distance): close to its own range,
 *                                      strafe, burst, reload, spade when it
 *                                      comes to that. RUNNING while he lives;
 *                                      SUCCESS on his death; FAILURE with
 *                                      nobody
 *   go_to <place> [radius]             walk to a place (jumping, digging,
 *                                      bridging as the mode allows), shooting
 *                                      what it meets on the way. SUCCESS there,
 *                                      FAILURE with no such place or no way
 *   retreat                            run to the nearest place the enemy
 *                                      cannot see, back turned. SUCCESS hidden
 *                                      (or after 10 s), FAILURE with nothing to
 *                                      run from
 *   investigate                        go to the place most worth searching,
 *                                      look round it, then forget it. SUCCESS
 *                                      looked, FAILURE none or no way
 *   roam                               walk to where the enemy was last met,
 *                                      else his base, else anywhere. Always
 *                                      RUNNING: this is what a bot does rather
 *                                      than stand
 *   follow [mate|caller|order]         keep a station 3 voxels from a player:
 *                                      the nearest team-mate (default), the
 *                                      caller of the ping it answers, or the
 *                                      order's man. RUNNING; FAILURE with
 *                                      nobody
 *   hold [place] [secs]                go to the place (default: here) and
 *                                      watch from it, sweeping the head,
 *                                      crouched if careful. SUCCESS after secs
 *                                      (default 8)
 *   throw_grenade [place]              throw at the place, or at what is worth
 *                                      one: stands, turns to the arc, lets go.
 *                                      SUCCESS thrown, FAILURE no arc, too
 *                                      near, none left
 *   evade                              run from the grenade that threatens it.
 *                                      RUNNING until it has burst
 *   ping <place> <label...>            ping the place for the team with one of
 *                                      the mode's labels ("Enemy", "Need help",
 *                                      "Sniper"). SUCCESS sent; FAILURE when
 *                                      the team has such a ping there, it
 *                                      pinged lately, or it is not one to say
 *                                      (teamwork)
 *   use <item> [self|enemy|group|<place>] [guide secs]
 *                                      use an inventory item, on itself or
 *                                      aimed at a point (the server's "inv
 *                                      <item> [x y z]"). With `enemy` and a
 *                                      guide time the head stays on that man
 *                                      for it. SUCCESS asked; FAILURE none
 *                                      held, just used, nothing to aim at
 *   lamp <on|off|auto>                 flashlight: lit, out (as a bot starts),
 *                                      or auto (lit by night). Never lit by
 *                                      day. SUCCESS at once
 *   obey                               do what the server's order says: go,
 *                                      hold, hunt a player, follow one. FAILURE
 *                                      with no order, SUCCESS when it is done
 *   look_around                        stand and look left, right and behind.
 *                                      SUCCESS after three looks
 *   reload                             reload now if the magazine is not full.
 *                                      SUCCESS asked, FAILURE nothing to do
 *
 * (bc_vocab_dump writes this list as text, for the docs and for a
 * server that wants to show what a tree may use.)
 */
#ifndef BC_VOCAB_H
#define BC_VOCAB_H

#include <stddef.h>

#include "bt.h"

/* Register every word, and persona.h's traits, into `v`. 0 if one did
 * not fit. */
int bc_vocab_register(bt_vocab *v);

/* The vocabulary as text, a word a line:
 *   "cond health_below <hp> -- its health is under that (of 100)"
 * Returns the length it has in full; writes at most out_size - 1. */
size_t bc_vocab_dump(char *out, size_t out_size);

/* How many words there are. */
int bc_vocab_count(void);

#endif
