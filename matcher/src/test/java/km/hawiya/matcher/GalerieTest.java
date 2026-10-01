package km.hawiya.matcher;

import com.machinezoo.sourceafis.FingerprintTemplate;
import org.junit.jupiter.api.Test;

import java.util.HashMap;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class GalerieTest {

    /** Personne fictive n : deux doigts (ISO 2 et 3) = deux graines différentes. */
    private static Map<Integer, byte[]> personne(int n) {
        return Map.of(2, EmpreinteSynthetique.generer(100L * n + 2), 3, EmpreinteSynthetique.generer(100L * n + 3));
    }

    private static Map<Integer, FingerprintTemplate> modeles(Map<Integer, byte[]> doigts, boolean nouvelleCapture) {
        Map<Integer, FingerprintTemplate> m = new HashMap<>();
        doigts.forEach((doigt, pixels) -> {
            byte[] image = nouvelleCapture
                    ? EmpreinteSynthetique.transformer(pixels, -6, 9, 5, doigt * 7L)
                    : pixels;
            m.put(doigt, Moteur.lire(EmpreinteSynthetique.modele(image)));
        });
        return m;
    }

    @Test
    void retrouveLaBonnePersonneParmiPlusieurs() {
        var galerie = new Galerie();
        for (int n = 1; n <= 5; n++) {
            galerie.ajouter("P" + n, modeles(personne(n), false));
        }
        assertEquals(5, galerie.nombrePersonnes());
        assertEquals(10, galerie.nombreModeles());

        var candidats = galerie.identifier(modeles(personne(3), true), Galerie.Fusion.SOMME, 3);
        assertEquals("P3", candidats.get(0).id());
        assertEquals(2, candidats.get(0).scoresDoigts().size());
        // Nettement devant le deuxième.
        assertTrue(candidats.get(0).score() > 2 * candidats.get(1).score(),
                "1er=" + candidats.get(0).score() + " 2e=" + candidats.get(1).score());
    }

    @Test
    void retirerUnePersonne() {
        var galerie = new Galerie();
        galerie.ajouter("P1", modeles(personne(1), false));
        assertTrue(galerie.retirer("P1"));
        assertEquals(0, galerie.nombrePersonnes());
    }
}
