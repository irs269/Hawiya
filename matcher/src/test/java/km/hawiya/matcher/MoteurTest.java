package km.hawiya.matcher;

import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class MoteurTest {

    static byte[] doigtA;
    static byte[] doigtB;

    @BeforeAll
    static void preparer() {
        doigtA = EmpreinteSynthetique.generer(1);
        doigtB = EmpreinteSynthetique.generer(2);
    }

    private static double score(byte[] sonde, byte[] candidat) {
        return Moteur.comparer(
                Moteur.lire(EmpreinteSynthetique.modele(sonde)),
                Moteur.lire(EmpreinteSynthetique.modele(candidat)));
    }

    @Test
    void versionDuMoteur() {
        assertTrue(Moteur.version().startsWith("sourceafis-"), Moteur.version());
    }

    @Test
    void memeDoigtDeplaceEtBruiteEstReconnu() {
        byte[] nouvelleCapture = EmpreinteSynthetique.transformer(doigtA, 8, 12, -7, 99);
        double s = score(nouvelleCapture, doigtA);
        assertTrue(s > 40, "score même doigt = " + s);
    }

    @Test
    void doigtsDifferentsNeSontPasConfondus() {
        double s = score(doigtA, doigtB);
        assertTrue(s < 20, "score doigts différents = " + s);
    }

    @Test
    void modeleSerialiseRelisible() {
        byte[] modele = EmpreinteSynthetique.modele(doigtA);
        assertTrue(modele.length > 100);
        double s = Moteur.comparer(Moteur.lire(modele), Moteur.lire(modele));
        assertTrue(s > 100, "score identique = " + s);
    }

    @Test
    void fusionDesScores() {
        Map<Integer, Double> scores = Map.of(2, 50.0, 3, 10.0, 4, 30.0, 5, 40.0);
        assertEquals(130.0, Galerie.fusionner(scores, Galerie.Fusion.SOMME), 1e-9);
        assertEquals(120.0, Galerie.fusionner(scores, Galerie.Fusion.MEILLEURS3), 1e-9);
    }
}
