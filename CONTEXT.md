# Mister

Context for the Mister fantasy-league analysis bot: it reads a league's market
and squads and recommends what to buy, sell, clause and field.

## Language

**Oferta recibida**:
An incoming offer for one of our players that is listed for sale.
_Avoid_: Bid, incoming bid

**Consejo de oferta**:
The accept/reject recommendation for a received offer, from the offer's relation to market value, the player's trend, and the profit over what we paid.
_Avoid_: Offer score, offer rating

**Titular**:
A player picked in the best lineup. A titular is never sold.
_Avoid_: Starter, XI

**Plusvalía**:
The profit of a sale over what we paid for the player.
_Avoid_: Margin, gain, return
