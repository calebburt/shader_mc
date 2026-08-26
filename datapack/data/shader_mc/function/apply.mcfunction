# Post effects are saved in the player's data, so this only has to land once.
# Order is the order they are applied in: reflections, then the light shafts they
# should be lit by, then bloom over both, then depth of field on the finished
# image.
posteffect add @s minecraft:ssr
posteffect add @s minecraft:volumetric
posteffect add @s minecraft:bloom
posteffect add @s minecraft:dof
scoreboard players set @s shader_mc.applied 4
