# Hand out the effects to anyone who does not have this version of the set yet.
# Bump the number here and in apply.mcfunction whenever the set changes, and
# every player picks the new one up on their next tick. Cheaper and less
# fragile than a grant-once advancement, which cannot be re-fired without
# renaming it or revoking it by hand.
execute as @a unless score @s shader_mc.applied matches 4 run function shader_mc:apply
